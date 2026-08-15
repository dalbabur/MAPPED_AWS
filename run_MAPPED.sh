#!/usr/bin/env bash
set -euo pipefail

function usage() {
  cat <<EOF
Usage: $0 --organism ORGANISM --outdir OUTDIR --library_layout LIB_LAYOUT --workdir WORKDIR --clean-mode CLEAN_MODE --cpu CPU [--ref-accession REF_ACCESSION] [--max_concurrent_downloads N] [--strain STRAIN]

Options:
  --organism        Organism name (e.g., "Acinetobacter baylyi") - required for metadata download
  --outdir          Output directory for pipeline results. Either a local path, or an
                    s3:// URI to run on AWS Batch (requires --workdir to also be s3://;
                    see AWS_SETUP.md).
  --workdir         Work directory for Nextflow 'work' files. Local path or s3:// URI,
                    matching --outdir.
  --library_layout  Library layout: 'single', 'paired', or 'both'
  --clean-mode      Clean up intermediate files and caches after pipeline completion.
                    Local paths only -- not supported with s3:// --outdir/--workdir
                    (use an S3 Lifecycle rule instead; see AWS_SETUP.md).
  --cpu             Number of CPUs to allocate per process
  --ref-accession   Optional: specific reference genome accession (e.g., "GCA_008931305.1"). 
                    If not provided, automatically selects the reference strain for the organism.
  --strain          Optional: filter metadata by strain token in 'ScientificName'.
                    Splits ScientificName on spaces and keeps rows where any token equals
                    or contains the provided string (case-insensitive).
                    Alias: '-strain' also accepted.
  --max_concurrent_downloads  Optional: Maximum number of concurrent downloads (default: 20)
  --aws_batch_queue        Optional: AWS Batch job queue name (only used with s3:// paths;
                    default 'mapped-spot-queue', see AWS_SETUP.md)
  --aws_batch_job_role_arn Optional: IAM role ARN each AWS Batch job assumes (only used
                    with s3:// paths; see AWS_SETUP.md §3.3)
  -h, --help        Show this help message and exit
EOF
}

# Parse arguments
ORGANISM=""
OUTDIR=""
LIB_LAYOUT=""
CLEAN_MODE="false"
CPU=""
WORKDIR=""
REF_ACCESSION=""
MAX_CONCURRENT_DOWNLOADS=""
STRAIN=""
AWS_BATCH_QUEUE=""
AWS_BATCH_JOB_ROLE_ARN=""

while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --organism)
      ORGANISM="$2"
      shift 2
      ;;
    --outdir)
      OUTDIR="$2"
      shift 2
      ;;
    --library_layout)
      LIB_LAYOUT="$2"
      shift 2
      ;;
    --workdir)
      WORKDIR="$2"
      shift 2
      ;;
    --clean-mode)
      CLEAN_MODE="true"
      shift
      ;;
    --cpu)
      CPU="$2"
      shift 2
      ;;
    --ref-accession)
      REF_ACCESSION="$2"
      shift 2
      ;;
    --max_concurrent_downloads)
      MAX_CONCURRENT_DOWNLOADS="$2"
      shift 2
      ;;
    --strain|-strain)
      STRAIN="$2"
      shift 2
      ;;
    --aws_batch_queue)
      AWS_BATCH_QUEUE="$2"
      shift 2
      ;;
    --aws_batch_job_role_arn)
      AWS_BATCH_JOB_ROLE_ARN="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

# Check required arguments
if [[ -z "$ORGANISM" || -z "$OUTDIR" || -z "$LIB_LAYOUT" || -z "$WORKDIR" ]]; then
  echo "Error: Missing required arguments."
  usage
  exit 1
fi

# Validate library_layout parameter
if [[ "$LIB_LAYOUT" != "single" && "$LIB_LAYOUT" != "paired" && "$LIB_LAYOUT" != "both" ]]; then
  echo "Error: Invalid library_layout value: $LIB_LAYOUT"
  echo "Valid values are: single, paired, both"
  exit 1
fi

# Detect AWS mode: --outdir/--workdir as s3:// URIs run the pipeline on AWS Batch
# instead of the local executor (see AWS_SETUP.md for the environment this expects).
NF_PROFILE_FLAG=""
if [[ "$OUTDIR" == s3://* || "$WORKDIR" == s3://* ]]; then
  if [[ "$OUTDIR" != s3://* || "$WORKDIR" != s3://* ]]; then
    echo "Error: --outdir and --workdir must both be s3:// URIs, or both be local paths."
    echo "  --outdir:  $OUTDIR"
    echo "  --workdir: $WORKDIR"
    exit 1
  fi
  NF_PROFILE_FLAG="-profile awsbatch"
  echo "Detected s3:// --outdir/--workdir: running with -profile awsbatch."
fi

# --clean-mode does local mv/rm surgery on OUTDIR/WORKDIR that has no S3 equivalent.
# Fail fast, before any pipeline stage runs, rather than after burning Batch compute time.
if [[ "$CLEAN_MODE" == "true" && -n "$NF_PROFILE_FLAG" ]]; then
  echo "Error: --clean-mode is not supported with s3:// --outdir/--workdir."
  echo "Use an S3 Lifecycle rule instead (see AWS_SETUP.md, 'Cost Controls')."
  exit 1
fi

# Convert OUTDIR to an absolute path and ensure it exists (local paths only)
if [[ "$OUTDIR" != s3://* ]]; then
  if [[ "$OUTDIR" != /* ]]; then
    OUTDIR="$(pwd)/$OUTDIR"
  fi
  mkdir -p "$OUTDIR"
fi

# Convert WORKDIR to an absolute path and ensure it exists (local paths only)
if [[ "$WORKDIR" != s3://* ]]; then
  if [[ "$WORKDIR" != /* ]]; then
    WORKDIR="$(pwd)/$WORKDIR"
  fi
  mkdir -p "$WORKDIR"
fi

# Step 1: Download metadata
echo "=== Step 1: Download metadata ==="
pushd 1_download_metadata_efetch > /dev/null 2>&1
nextflow run main.nf ${NF_PROFILE_FLAG} -work-dir "$WORKDIR" --organism "$ORGANISM" --outdir "$OUTDIR" --library_layout "$LIB_LAYOUT" ${STRAIN:+--strain "$STRAIN"} ${AWS_BATCH_QUEUE:+--aws_batch_queue "$AWS_BATCH_QUEUE"} ${AWS_BATCH_JOB_ROLE_ARN:+--aws_batch_job_role_arn "$AWS_BATCH_JOB_ROLE_ARN"} -resume
popd > /dev/null 2>&1

# Step 2: Download FASTQ
echo "=== Step 2: Download FASTQ ==="
pushd 2_download_fastq > /dev/null 2>&1
nextflow run main.nf ${NF_PROFILE_FLAG} -work-dir "$WORKDIR" --outdir "$OUTDIR" ${MAX_CONCURRENT_DOWNLOADS:+--max_concurrent_downloads $MAX_CONCURRENT_DOWNLOADS} ${AWS_BATCH_QUEUE:+--aws_batch_queue "$AWS_BATCH_QUEUE"} ${AWS_BATCH_JOB_ROLE_ARN:+--aws_batch_job_role_arn "$AWS_BATCH_JOB_ROLE_ARN"} -resume
popd > /dev/null 2>&1

# Step 3: Download reference genome
echo "=== Step 3: Download reference genome ==="
pushd 3_download_reference_genome > /dev/null 2>&1
if [[ -n "$REF_ACCESSION" ]]; then
  nextflow run main.nf ${NF_PROFILE_FLAG} -work-dir "$WORKDIR" --ref_accession "$REF_ACCESSION" --outdir "$OUTDIR" ${CPU:+--cpu $CPU} ${AWS_BATCH_QUEUE:+--aws_batch_queue "$AWS_BATCH_QUEUE"} ${AWS_BATCH_JOB_ROLE_ARN:+--aws_batch_job_role_arn "$AWS_BATCH_JOB_ROLE_ARN"} -resume
else
  nextflow run main.nf ${NF_PROFILE_FLAG} -work-dir "$WORKDIR" --organism "$ORGANISM" --outdir "$OUTDIR" ${CPU:+--cpu $CPU} ${AWS_BATCH_QUEUE:+--aws_batch_queue "$AWS_BATCH_QUEUE"} ${AWS_BATCH_JOB_ROLE_ARN:+--aws_batch_job_role_arn "$AWS_BATCH_JOB_ROLE_ARN"} -resume
fi
popd > /dev/null 2>&1

# Step 4: Generate count/tpm matrix
echo "=== Step 4: Generate count/tpm matrix ==="
pushd 4_generate_count_matrix > /dev/null 2>&1
nextflow run main.nf ${NF_PROFILE_FLAG} -work-dir "$WORKDIR" --outdir "$OUTDIR" ${CPU:+--cpu $CPU} ${AWS_BATCH_QUEUE:+--aws_batch_queue "$AWS_BATCH_QUEUE"} ${AWS_BATCH_JOB_ROLE_ARN:+--aws_batch_job_role_arn "$AWS_BATCH_JOB_ROLE_ARN"} -resume
popd > /dev/null 2>&1

# Print sample counts after Step 4
echo "=== Sample Count Summary ==="
if [[ "$OUTDIR" == s3://* ]]; then
  # Count rows (which are now unique experiments after merging in DATA_VALIDATION)
  if download_csv=$(aws s3 cp "$OUTDIR/samplesheet/samplesheet_download.csv" - 2>/dev/null); then
    download_count=$(printf '%s\n' "$download_csv" | tail -n +2 | grep -c '^')
    echo "Downloaded experiments (samplesheet_download.csv): $download_count"
  else
    echo "samplesheet_download.csv not found"
  fi

  if filtered_csv=$(aws s3 cp "$OUTDIR/samplesheet/samplesheet.csv" - 2>/dev/null); then
    filtered_count=$(printf '%s\n' "$filtered_csv" | tail -n +2 | grep -c '^')
    echo "Experiments passing filtration (samplesheet.csv): $filtered_count"
  else
    echo "samplesheet.csv not found"
  fi
else
  if [[ -f "$OUTDIR/samplesheet/samplesheet_download.csv" ]]; then
    # Count rows (which are now unique experiments after merging in DATA_VALIDATION)
    download_count=$(tail -n +2 "$OUTDIR/samplesheet/samplesheet_download.csv" | grep -c '^')
    echo "Downloaded experiments (samplesheet_download.csv): $download_count"
  else
    echo "samplesheet_download.csv not found"
  fi

  if [[ -f "$OUTDIR/samplesheet/samplesheet.csv" ]]; then
    # Count rows (which are unique experiments after DATA_VALIDATION merging)
    filtered_count=$(tail -n +2 "$OUTDIR/samplesheet/samplesheet.csv" | grep -c '^')
    echo "Experiments passing filtration (samplesheet.csv): $filtered_count"
  else
    echo "samplesheet.csv not found"
  fi
fi
echo "============================="

echo "All steps completed successfully!"

if [[ "$CLEAN_MODE" == "true" ]]; then
  echo "=== Clean mode enabled: cleaning intermediate files ==="
  
  # Preserve ref_genome folder by moving it to a temporary location
  if [[ -d "$OUTDIR/seqFiles/ref_genome" ]]; then
    echo "Preserving ref_genome folder..."
    mv "$OUTDIR/seqFiles/ref_genome" "$OUTDIR/ref_genome_temp"
  fi
  
  # Delete everything in OUTDIR except expression_matrices and samplesheet
  find "$OUTDIR" -mindepth 1 -maxdepth 1 ! -name expression_matrices ! -name samplesheet ! -name ref_genome_temp -exec rm -rf {} +
  
  # Move ref_genome back to the same level as expression_matrices and samplesheet
  if [[ -d "$OUTDIR/ref_genome_temp" ]]; then
    echo "Moving ref_genome to final location..."
    mv "$OUTDIR/ref_genome_temp" "$OUTDIR/ref_genome"
  fi
  
  # Delete work, .nextflow, and .nextflow.log in module directories
  for sub in 1_download_metadata_efetch 2_download_fastq 3_download_reference_genome 4_generate_count_matrix; do
    rm -rf "$sub/work" "$sub/.nextflow" "$sub/.nextflow.log"
  done
  
  # Clean the global Nextflow work directory
  rm -rf "$WORKDIR"
fi 
