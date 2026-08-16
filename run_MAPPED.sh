#!/usr/bin/env bash
set -euo pipefail

function usage() {
  cat <<EOF
Usage: $0 --organism ORGANISM --outdir OUTDIR --library_layout LIB_LAYOUT --workdir WORKDIR --clean-mode CLEAN_MODE --cpu CPU [--ref-accession REF_ACCESSION] [--max_concurrent_downloads N] [--strain STRAIN] [--bioproject BIOPROJECT] [--sra_accessions ACC1,ACC2,...] [--quantifier bowtie2|salmon]

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
  --bioproject      Optional: narrow the SRA metadata search to a specific BioProject
                    accession (e.g. "PRJNA796354"), for targeting a named expression
                    compendium instead of every RNA-seq run for --organism.
  --sra_accessions  Optional: comma-separated list of exact SRA/ENA experiment
                    accessions (e.g. "SRX14436231,SRX14436232"). Bypasses the
                    organism/strategy search (and --bioproject) entirely -- use this for
                    exact control over which samples run, such as a smoke test.
  --quantifier      Optional: gene-quantification method for Step 4 (default: 'bowtie2').
                    'bowtie2' aligns to the whole genome with Bowtie2 and assigns reads to
                    every gene type in the GFF (protein-coding, tRNA, rRNA, ncRNA) with
                    featureCounts. 'salmon' uses the original CDS-only pseudo-alignment
                    path (EXTRACT_CDS + SALMON_INDEX + SALMON_QUANT). See
                    4_generate_count_matrix/README.md for the tradeoffs.
  --max_concurrent_downloads  Optional: Maximum number of concurrent downloads (default: 20)
  --aws_batch_queue        Optional: AWS Batch job queue name (only used with s3:// paths;
                    default 'mapped-spot-queue', see AWS_SETUP.md)
  --aws_batch_job_role_arn Optional: IAM role ARN each AWS Batch job assumes (only used
                    with s3:// paths; see AWS_SETUP.md §3.3)
  --force           Optional: proceed even if --outdir already holds results from a
                    different --organism/--strain/--bioproject/--sra_accessions/
                    --library_layout/--ref-accession/--quantifier -- without this flag,
                    such a mismatch is refused (see 'Output directory reuse' below).
  --skip-processed  Optional: s3:// mode only. Before downloading FASTQ, query the Glue
                    Data Catalog (AWS_SETUP.md §14) for samples already fully processed
                    for this --organism against the same reference genome, and skip
                    re-downloading/re-quantifying them. Moves Step 3 (reference genome)
                    before Step 2 so the reference is known before filtering.
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
BIOPROJECT=""
SRA_ACCESSIONS=""
# Defaulted here (matching module 4's own default) rather than left empty, so the
# collision-guard manifest below always records the *actual* effective quantifier --
# leaving this blank would let module 4's default apply silently without the manifest
# ever reflecting it, defeating the mismatch check for runs that omit --quantifier.
QUANTIFIER="bowtie2"
AWS_BATCH_QUEUE=""
AWS_BATCH_JOB_ROLE_ARN=""
FORCE="false"
SKIP_PROCESSED="false"

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
    --bioproject)
      BIOPROJECT="$2"
      shift 2
      ;;
    --sra_accessions)
      SRA_ACCESSIONS="$2"
      shift 2
      ;;
    --quantifier)
      QUANTIFIER="$2"
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
    --force)
      FORCE="true"
      shift
      ;;
    --skip-processed)
      SKIP_PROCESSED="true"
      shift
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

# Validate quantifier parameter (empty is fine -- module 4 defaults to 'bowtie2')
if [[ -n "$QUANTIFIER" && "$QUANTIFIER" != "bowtie2" && "$QUANTIFIER" != "salmon" ]]; then
  echo "Error: Invalid quantifier value: $QUANTIFIER"
  echo "Valid values are: bowtie2, salmon"
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

# --skip-processed queries the Glue Data Catalog, which only exists in S3 mode. Fail fast
# for the same reason as the --clean-mode check above.
if [[ "$SKIP_PROCESSED" == "true" && -z "$NF_PROFILE_FLAG" ]]; then
  echo "Error: --skip-processed requires s3:// --outdir/--workdir (the Glue Data Catalog is S3-only; see AWS_SETUP.md §14)."
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

# --- Outdir collision guard --------------------------------------------------
# Several publishDir directives (4_generate_count_matrix/main.nf) use overwrite:true,
# so re-running against an --outdir that already holds results from a DIFFERENT
# configuration would silently clobber them. Guard against that by recording the
# data-identity parameters (the ones that determine *what* ends up in outdir -- not
# --workdir/--cpu, which only affect caching/performance and are fine to change across
# a legitimate resume) in a small manifest at the root of --outdir, and refusing to
# proceed if a new invocation's parameters don't match what's already there. Works
# identically in local and S3 mode, and doesn't depend on the Glue catalog (Step 5,
# below) since that only gets written *after* Step 4 completes -- too late to prevent
# the overwrite this guards against, and only present in S3 mode.
MANIFEST_PATH="$OUTDIR/.mapped_run_manifest"
if [[ "$OUTDIR" == s3://* ]]; then
  EXISTING_MANIFEST=$(aws s3 cp "$MANIFEST_PATH" - 2>/dev/null || true)
elif [[ -f "$MANIFEST_PATH" ]]; then
  EXISTING_MANIFEST=$(cat "$MANIFEST_PATH")
else
  EXISTING_MANIFEST=""
fi

WRITE_MANIFEST="true"
if [[ -n "$EXISTING_MANIFEST" ]]; then
  PREV_ORGANISM=$(printf '%s\n' "$EXISTING_MANIFEST" | grep -m1 '^ORGANISM=' | cut -d= -f2-)
  PREV_STRAIN=$(printf '%s\n' "$EXISTING_MANIFEST" | grep -m1 '^STRAIN=' | cut -d= -f2-)
  PREV_BIOPROJECT=$(printf '%s\n' "$EXISTING_MANIFEST" | grep -m1 '^BIOPROJECT=' | cut -d= -f2-)
  PREV_SRA_ACCESSIONS=$(printf '%s\n' "$EXISTING_MANIFEST" | grep -m1 '^SRA_ACCESSIONS=' | cut -d= -f2-)
  PREV_LIB_LAYOUT=$(printf '%s\n' "$EXISTING_MANIFEST" | grep -m1 '^LIBRARY_LAYOUT=' | cut -d= -f2-)
  PREV_REF_ACCESSION=$(printf '%s\n' "$EXISTING_MANIFEST" | grep -m1 '^REF_ACCESSION=' | cut -d= -f2-)
  PREV_QUANTIFIER=$(printf '%s\n' "$EXISTING_MANIFEST" | grep -m1 '^QUANTIFIER=' | cut -d= -f2-)
  PREV_CREATED_AT=$(printf '%s\n' "$EXISTING_MANIFEST" | grep -m1 '^CREATED_AT=' | cut -d= -f2-)

  # Manifests written before --quantifier existed have no QUANTIFIER= line, which reads
  # back as empty here -- treat that the same as an explicit '' (i.e. module 4's own
  # 'bowtie2' default) rather than flagging every pre-existing outdir as a mismatch.
  MISMATCH=""
  [[ "$PREV_ORGANISM" != "$ORGANISM" ]] && MISMATCH+=$'\n'"  --organism:        '$PREV_ORGANISM' -> '$ORGANISM'"
  [[ "$PREV_STRAIN" != "$STRAIN" ]] && MISMATCH+=$'\n'"  --strain:          '$PREV_STRAIN' -> '$STRAIN'"
  [[ "$PREV_BIOPROJECT" != "$BIOPROJECT" ]] && MISMATCH+=$'\n'"  --bioproject:      '$PREV_BIOPROJECT' -> '$BIOPROJECT'"
  [[ "$PREV_SRA_ACCESSIONS" != "$SRA_ACCESSIONS" ]] && MISMATCH+=$'\n'"  --sra_accessions:  '$PREV_SRA_ACCESSIONS' -> '$SRA_ACCESSIONS'"
  [[ "$PREV_LIB_LAYOUT" != "$LIB_LAYOUT" ]] && MISMATCH+=$'\n'"  --library_layout:  '$PREV_LIB_LAYOUT' -> '$LIB_LAYOUT'"
  [[ "$PREV_REF_ACCESSION" != "$REF_ACCESSION" ]] && MISMATCH+=$'\n'"  --ref-accession:   '$PREV_REF_ACCESSION' -> '$REF_ACCESSION'"
  [[ "$PREV_QUANTIFIER" != "$QUANTIFIER" ]] && MISMATCH+=$'\n'"  --quantifier:      '$PREV_QUANTIFIER' -> '$QUANTIFIER'"

  if [[ -n "$MISMATCH" ]]; then
    if [[ "$FORCE" != "true" ]]; then
      echo "Error: --outdir '$OUTDIR' already holds results from a DIFFERENT configuration (registered $PREV_CREATED_AT):$MISMATCH"
      echo ""
      echo "Re-running here would silently overwrite those results. Choose a different --outdir,"
      echo "or pass --force to intentionally overwrite and re-register this outdir."
      exit 1
    fi
    echo "WARNING: --outdir '$OUTDIR' had a different configuration (registered $PREV_CREATED_AT) -- proceeding due to --force:$MISMATCH"
  else
    echo "Resuming previous run against --outdir '$OUTDIR' (first registered $PREV_CREATED_AT)."
    WRITE_MANIFEST="false"
  fi
fi

if [[ "$WRITE_MANIFEST" == "true" ]]; then
  MANIFEST_CONTENT=$(cat <<MANIFEST
ORGANISM=$ORGANISM
STRAIN=$STRAIN
BIOPROJECT=$BIOPROJECT
SRA_ACCESSIONS=$SRA_ACCESSIONS
LIBRARY_LAYOUT=$LIB_LAYOUT
REF_ACCESSION=$REF_ACCESSION
QUANTIFIER=$QUANTIFIER
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MANIFEST
)
  if [[ "$OUTDIR" == s3://* ]]; then
    printf '%s\n' "$MANIFEST_CONTENT" | aws s3 cp - "$MANIFEST_PATH"
  else
    printf '%s\n' "$MANIFEST_CONTENT" > "$MANIFEST_PATH"
  fi
fi
# ------------------------------------------------------------------------------

# Step 3 is a function, not an inline block, because --skip-processed needs to run it
# earlier than usual (see below) -- Stage 3 has no data dependency on Stages 1/2 (only
# needs --organism/--ref-accession, both known from CLI args alone), so moving it earlier
# changes nothing about its own correctness, but it does let us resolve the actual
# reference genome accession *before* deciding what to skip.
run_step3_reference_genome() {
  echo "=== Step 3: Download reference genome ==="
  pushd 3_download_reference_genome > /dev/null 2>&1
  if [[ -n "$REF_ACCESSION" ]]; then
    nextflow run main.nf ${NF_PROFILE_FLAG} -work-dir "$WORKDIR" --ref_accession "$REF_ACCESSION" --outdir "$OUTDIR" ${CPU:+--cpu $CPU} ${AWS_BATCH_QUEUE:+--aws_batch_queue "$AWS_BATCH_QUEUE"} ${AWS_BATCH_JOB_ROLE_ARN:+--aws_batch_job_role_arn "$AWS_BATCH_JOB_ROLE_ARN"} -resume
  else
    nextflow run main.nf ${NF_PROFILE_FLAG} -work-dir "$WORKDIR" --organism "$ORGANISM" --outdir "$OUTDIR" ${CPU:+--cpu $CPU} ${AWS_BATCH_QUEUE:+--aws_batch_queue "$AWS_BATCH_QUEUE"} ${AWS_BATCH_JOB_ROLE_ARN:+--aws_batch_job_role_arn "$AWS_BATCH_JOB_ROLE_ARN"} -resume
  fi
  popd > /dev/null 2>&1
}

# Step 1: Download metadata
echo "=== Step 1: Download metadata ==="
pushd 1_download_metadata_efetch > /dev/null 2>&1
nextflow run main.nf ${NF_PROFILE_FLAG} -work-dir "$WORKDIR" --organism "$ORGANISM" --outdir "$OUTDIR" --library_layout "$LIB_LAYOUT" ${STRAIN:+--strain "$STRAIN"} ${BIOPROJECT:+--bioproject "$BIOPROJECT"} ${SRA_ACCESSIONS:+--sra_accessions "$SRA_ACCESSIONS"} ${AWS_BATCH_QUEUE:+--aws_batch_queue "$AWS_BATCH_QUEUE"} ${AWS_BATCH_JOB_ROLE_ARN:+--aws_batch_job_role_arn "$AWS_BATCH_JOB_ROLE_ARN"} -resume
popd > /dev/null 2>&1

# --skip-processed: run Step 3 now (instead of its usual position after Step 2) so the
# actual reference genome accession is known, then filter metadata/sample_id.csv against
# the Glue catalog before Step 2 ever downloads FASTQ for an already-processed sample.
STAGE3_DONE="false"
if [[ "$SKIP_PROCESSED" == "true" ]]; then
  run_step3_reference_genome
  STAGE3_DONE="true"

  REF_ACCESSION_USED=$(aws s3 ls "$OUTDIR/seqFiles/ref_genome/" 2>/dev/null | grep -oE 'GC[AF]_[0-9]+\.[0-9]+' | sort -u | head -n1 || true)
  if [[ -z "$REF_ACCESSION_USED" ]]; then
    echo "WARNING: could not resolve a reference genome accession from $OUTDIR/seqFiles/ref_genome/ -- skipping --skip-processed filtering for this run."
  else
    # Best-effort: the specific NCBI annotation release for $REF_ACCESSION_USED (distinct
    # from the accession itself -- see catalog/filter_processed_samples.py's docstring for
    # why this matters). datasets_summary.json is JSON-lines, one record per candidate
    # genome for auto-select mode, so match the record for the accession actually
    # downloaded rather than assuming line 1. Empty on any failure -- filter_processed_
    # samples.py falls back to organism + ref-accession-used matching when this is blank.
    ANNOTATION_VERSION=$(aws s3 cp "$OUTDIR/seqFiles/ref_genome/datasets_summary.json" - 2>/dev/null | python3 -c "
import json, sys
target = '$REF_ACCESSION_USED'
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        record = json.loads(line)
    except json.JSONDecodeError:
        continue
    if record.get('accession') != target:
        continue
    info = record.get('annotation_info') or {}
    print(info.get('name') or info.get('release_date') or '')
    break
" 2>/dev/null || true)

    echo "=== Filtering already-processed samples from catalog ==="
    if FILTER_OUTPUT=$(python3 catalog/filter_processed_samples.py --outdir "$OUTDIR" --organism "$ORGANISM" --ref-accession-used "$REF_ACCESSION_USED" ${ANNOTATION_VERSION:+--annotation-version "$ANNOTATION_VERSION"}); then
      echo "$FILTER_OUTPUT"
      REMAINING_COUNT=$(printf '%s\n' "$FILTER_OUTPUT" | grep -m1 '^REMAINING_COUNT=' | cut -d= -f2-)
      if [[ "$REMAINING_COUNT" == "0" ]]; then
        echo "All requested samples for --organism '$ORGANISM' are already processed against $REF_ACCESSION_USED -- nothing new to run."
        exit 0
      fi
    else
      echo "$FILTER_OUTPUT"
      echo "WARNING: --skip-processed filtering failed (non-fatal) -- proceeding with the full, unfiltered sample list."
    fi
    echo "============================="
  fi
fi

# Step 2: Download FASTQ
echo "=== Step 2: Download FASTQ ==="
pushd 2_download_fastq > /dev/null 2>&1
nextflow run main.nf ${NF_PROFILE_FLAG} -work-dir "$WORKDIR" --outdir "$OUTDIR" ${MAX_CONCURRENT_DOWNLOADS:+--max_concurrent_downloads $MAX_CONCURRENT_DOWNLOADS} ${AWS_BATCH_QUEUE:+--aws_batch_queue "$AWS_BATCH_QUEUE"} ${AWS_BATCH_JOB_ROLE_ARN:+--aws_batch_job_role_arn "$AWS_BATCH_JOB_ROLE_ARN"} -resume
popd > /dev/null 2>&1

# Step 3: Download reference genome (already done above if --skip-processed)
if [[ "$STAGE3_DONE" != "true" ]]; then
  run_step3_reference_genome
fi

# Step 4: Generate count/tpm matrix
echo "=== Step 4: Generate count/tpm matrix ==="
pushd 4_generate_count_matrix > /dev/null 2>&1
nextflow run main.nf ${NF_PROFILE_FLAG} -work-dir "$WORKDIR" --outdir "$OUTDIR" ${CPU:+--cpu $CPU} ${QUANTIFIER:+--quantifier "$QUANTIFIER"} ${AWS_BATCH_QUEUE:+--aws_batch_queue "$AWS_BATCH_QUEUE"} ${AWS_BATCH_JOB_ROLE_ARN:+--aws_batch_job_role_arn "$AWS_BATCH_JOB_ROLE_ARN"} -resume
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

# Step 5: Register this run in the Glue Data Catalog (S3 mode only -- see AWS_SETUP.md §14)
if [[ "$OUTDIR" == s3://* ]]; then
  echo "=== Step 5: Register run in catalog ==="
  python3 catalog/register_run.py \
    --outdir "$OUTDIR" --workdir "$WORKDIR" --organism "$ORGANISM" \
    --library-layout "$LIB_LAYOUT" \
    ${STRAIN:+--strain "$STRAIN"} ${BIOPROJECT:+--bioproject "$BIOPROJECT"} \
    ${SRA_ACCESSIONS:+--sra-accessions "$SRA_ACCESSIONS"} \
    ${REF_ACCESSION:+--ref-accession "$REF_ACCESSION"} \
    --quantifier "$QUANTIFIER" \
    ${CPU:+--cpu "$CPU"} ${AWS_BATCH_QUEUE:+--aws-batch-queue "$AWS_BATCH_QUEUE"} \
    || echo "WARNING: catalog registration failed (non-fatal) -- pipeline outputs in S3 are unaffected. Re-run 'python3 catalog/register_run.py --outdir $OUTDIR ...' manually to retry."
  echo "============================="
fi

echo "All steps completed successfully!"

if [[ "$CLEAN_MODE" == "true" ]]; then
  echo "=== Clean mode enabled: cleaning intermediate files ==="
  
  # Preserve ref_genome folder by moving it to a temporary location
  if [[ -d "$OUTDIR/seqFiles/ref_genome" ]]; then
    echo "Preserving ref_genome folder..."
    mv "$OUTDIR/seqFiles/ref_genome" "$OUTDIR/ref_genome_temp"
  fi
  
  # Delete everything in OUTDIR except expression_matrices, samplesheet, and the
  # collision-guard manifest (which describes what's in the two directories being
  # kept -- deleting it here would make a future run against this same outdir think
  # it's untouched, defeating the guard)
  find "$OUTDIR" -mindepth 1 -maxdepth 1 ! -name expression_matrices ! -name samplesheet ! -name ref_genome_temp ! -name .mapped_run_manifest -exec rm -rf {} +
  
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
