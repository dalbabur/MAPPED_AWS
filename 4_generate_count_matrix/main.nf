//
// Required parameters
//
params.outdir    = null

if ( ! params.outdir )    error "Please provide --outdir"

// Resource configuration: threads per task and max parallel runs
params.cpu = params.cpu ?: 20
def threads_per_task = 4
def max_parallel = (params.cpu / threads_per_task) as Integer

// Auto-detect reference genome and GFF in seqFiles/ref_genome under outdir.
// Uses Nextflow's file()/Path API (not java.io.File) so this also works when
// params.outdir is an s3:// URI, not just a local path.
def refDir = file("${params.outdir}/seqFiles/ref_genome")
if ( ! refDir.exists() ) error "Reference genome directory not found: ${refDir}"
def refDirFiles = refDir.listFiles()
def fastaFiles = refDirFiles.findAll { it.name.endsWith('.fna') || it.name.endsWith('.fa') }
if ( fastaFiles.size() == 0 ) error "No FASTA (.fna/.fa) file found in ${refDir}"
if ( fastaFiles.size() > 1 ) error "Multiple FASTA files found in ${refDir}: ${fastaFiles*.name}"
params.ref_genome = fastaFiles[0].toUriString()
def gffFiles = refDirFiles.findAll { it.name.endsWith('.gff') }
if ( gffFiles.size() == 0 ) error "No GFF (.gff) file found in ${refDir}"
if ( gffFiles.size() > 1 ) error "Multiple GFF files found in ${refDir}: ${gffFiles*.name}"
params.ref_gff = gffFiles[0].toUriString()

// Process: extract CDS
//
process EXTRACT_CDS {
    tag 'extract_cds'
    container 'quay.io/biocontainers/gffread:0.9.12--0'
    errorStrategy 'ignore'

    input:
      path genome
      path annotation

    output:
      path 'cds.fa', optional: true

    script:
    """
    gffread ${annotation} -g ${genome} -x cds.fa
    """
}

//
// Process: build Salmon index
//
process SALMON_INDEX {
    tag 'salmon_index'
    container 'quay.io/biocontainers/salmon:1.10.3--h45fbf2d_4'
    errorStrategy 'ignore'

    input:
      path cds_fa

    output:
      path 'salmon_index', optional: true

    script:
    """
    salmon index -t ${cds_fa} -i salmon_index --gencode
    """
}

//
// Process: FastQC on raw reads
//
process FASTQC {
    cache true
    tag '$sample'
    container 'quay.io/biocontainers/fastqc:0.12.1--hdfd78af_0'
    publishDir "${params.outdir}/fastqc", mode: 'copy'
    cpus threads_per_task
    maxForks max_parallel
    errorStrategy 'ignore'

    input:
      tuple val(sample), path(fq1), path(fq2)

    output:
      path "*.{zip,html}", optional: true, emit: fastqc_files

    script:
    def fastq_files = fq2 ? "${fq1} ${fq2}" : "${fq1}"
    """
    # Ensure sample name is not null or empty
    if [ -z "${sample}" ] || [ "${sample}" = "null" ]; then
        echo "ERROR: Invalid sample name: ${sample}" >&2
        exit 0  # Exit gracefully to not break the pipeline
    fi
    
    fastqc --threads 4 -o . ${fastq_files} || true
    # Check if FastQC produced output
    if ! ls *.zip 1> /dev/null 2>&1; then
        echo "FastQC failed for sample ${sample}" >&2
    fi
    
    # Remove any files with 'null' in the name to prevent downstream issues
    rm -f *null* 2>/dev/null || true
    """
}

//
// Process: TrimGalore
//
process TRIMGALORE {
    cache true
    tag '$sample'
    container 'quay.io/biocontainers/trim-galore:0.6.9--hdfd78af_0'
    publishDir "${params.outdir}/trimmed", mode: 'copy'
    cpus threads_per_task
    maxForks max_parallel
    errorStrategy 'ignore'

    input:
      tuple val(sample), path(reads)

    output:
      tuple val(sample),
            path("*.fq.gz"), optional: true, emit: trimmed_reads

    script:
    def is_paired = reads instanceof List && reads.size() == 2
    if (is_paired) {
        """
        trim_galore --cores 4 --paired --basename ${sample} --output_dir . ${reads[0]} ${reads[1]} || true
        # Check if trimming succeeded and create dummy files if not
        if ! ls *.fq.gz 1> /dev/null 2>&1; then
            echo "TRIMGALORE failed for sample ${sample}" >&2
        fi
        """
    } else {
        def read_file = reads instanceof List ? reads[0] : reads
        """
        trim_galore --cores 4 --basename ${sample} --output_dir . ${read_file} || true
        # Check if trimming succeeded and create dummy files if not  
        if ! ls *.fq.gz 1> /dev/null 2>&1; then
            echo "TRIMGALORE failed for sample ${sample}" >&2
        fi
        """
    }
}

//
// Process: Salmon quantification
//
process SALMON_QUANT {
    cache true
    tag '$sample'
    container 'quay.io/biocontainers/salmon:1.10.3--h45fbf2d_4'
    publishDir "${params.outdir}/salmon", mode: 'copy'
    cpus threads_per_task
    maxForks max_parallel
    errorStrategy 'ignore'

    input:
      tuple val(sample), path(reads)
      path index

    output:
      path "${sample}_quant", optional: true, emit: quant_dir

    script:
    def read_input = reads.size() == 2 ? "-1 ${reads[0]} -2 ${reads[1]}" : "-r ${reads[0]}"
    """
    salmon quant \
      -i ${index} -l A \
      ${read_input} \
      -o ${sample}_quant \
      --validateMappings \
      --minAssignedFrags 10 \
      -p 4
    
    # Create a flag file to indicate successful completion
    touch ${sample}_quant/salmon_success.flag
    """
}

//
// Process: merge count matrices by experiment ID
//
process MERGE_COUNTS {
    publishDir "${params.outdir}/expression_matrices", mode: 'copy'
    container 'felixlohmeier/pandas:1.3.3'
    errorStrategy 'ignore'

    input:
      path quant_dirs
      path passed_samples_file

    output:
      path 'tpm.csv', optional: true
      path 'log_tpm.csv', optional: true
      path 'counts.csv', optional: true

    script:
    """
    python3 - << 'EOF'
import os
import pandas as pd
import numpy as np
from collections import defaultdict

# Read passed sample IDs
passed_sample_ids = set()
if os.path.exists('${passed_samples_file}'):
    with open('${passed_samples_file}', 'r') as f:
        for line in f:
            line = line.strip()
            if line:
                passed_sample_ids.add(line)

print(f"Found {len(passed_sample_ids)} passed sample IDs")

# Find all quant directories
all_quant_dirs = [d for d in os.listdir('.') if d.endswith('_quant')]
# Filter to only include directories with successful salmon runs (those with salmon_success.flag)
quant_dirs = []
failed_samples = []
for d in all_quant_dirs:
    flag_file = os.path.join(d, 'salmon_success.flag')
    quant_file = os.path.join(d, 'quant.sf')
    if os.path.exists(flag_file) and os.path.exists(quant_file):
        quant_dirs.append(d)
    else:
        failed_samples.append(d.replace('_quant', ''))

print(f"Found {len(all_quant_dirs)} total quantification directories")
print(f"Found {len(quant_dirs)} successful quantification directories")
if failed_samples:
    print(f"Skipped {len(failed_samples)} failed samples: {', '.join(failed_samples)}")

# Group by experiment ID and collect data
experiment_data = defaultdict(list)
gene_ids = None

for quant_dir in quant_dirs:
    sample_name = quant_dir.replace('_quant', '')
    
    # Extract experiment ID (everything before the first underscore)
    # This handles SRX_SRR, DRX_DRR, and ERX_ERR patterns
    experiment_id = sample_name.split('_')[0]
    
    # Get base sample name (remove _val_1/_val_2 suffixes for paired-end or _trimmed for single-end)
    base_sample_name = sample_name.replace('_val_1', '').replace('_val_2', '').replace('_trimmed', '')
    
    # Only process samples from passed experiments
    if base_sample_name not in passed_sample_ids:
        print(f"Skipping {sample_name} (base sample {base_sample_name} not in passed samples)")
        continue
    
    # Read quantification file
    quant_file = os.path.join(quant_dir, 'quant.sf')
    if not os.path.exists(quant_file):
        print(f"Warning: {quant_file} not found")
        continue
    
    df = pd.read_csv(quant_file, sep='\\t')
    
    # Store gene IDs from first file
    if gene_ids is None:
        gene_ids = df['Name'].tolist()
    
    # Store counts and TPM data for this experiment
    experiment_data[experiment_id].append({
        'sample': sample_name,
        'base_sample': base_sample_name,
        'counts': df['NumReads'].tolist(),
        'tpm': df['TPM'].tolist(),
        'length': df['Length'].tolist()
    })

print(f"Grouped into {len(experiment_data)} experiments")

# Merge data by experiment
final_counts = {}
final_tpm = {}

for experiment_id, runs in experiment_data.items():
    if len(runs) == 1:
        # Single run - use data directly, use experiment ID as column header
        final_counts[experiment_id] = runs[0]['counts']
        final_tpm[experiment_id] = runs[0]['tpm']
    else:
        # Multiple runs - sum counts and recalculate TPM
        print(f"Merging {len(runs)} runs for experiment {experiment_id}")
        
        # Sum counts across runs
        summed_counts = [0] * len(gene_ids)
        avg_lengths = [0] * len(gene_ids)
        
        for run in runs:
            for i in range(len(gene_ids)):
                summed_counts[i] += run['counts'][i]
                avg_lengths[i] = run['length'][i]  # Length should be same across runs
        
        # Calculate TPM from summed counts
        # TPM = (counts / length) * 1e6 / sum(counts / length)
        rpk = [summed_counts[i] / avg_lengths[i] if avg_lengths[i] > 0 else 0 for i in range(len(gene_ids))]
        scaling_factor = sum(rpk) / 1e6 if sum(rpk) > 0 else 1
        recalculated_tpm = [rpk[i] / scaling_factor if scaling_factor > 0 else 0 for i in range(len(gene_ids))]
        
        # Use experiment ID as column header
        final_counts[experiment_id] = summed_counts
        final_tpm[experiment_id] = recalculated_tpm

# Create output matrices
if gene_ids and final_counts:
    # Sort experiment IDs for consistent output
    sorted_experiments = sorted(final_counts.keys())
    
    # Write counts matrix
    with open('counts.csv', 'w') as f:
        f.write('GeneID,' + ','.join(sorted_experiments) + '\\n')
        for i, gene_id in enumerate(gene_ids):
            f.write(gene_id)
            for exp_id in sorted_experiments:
                f.write(f',{final_counts[exp_id][i]}')
            f.write('\\n')
    
    # Write TPM matrix  
    with open('tpm.csv', 'w') as f:
        f.write('GeneID,' + ','.join(sorted_experiments) + '\\n')
        for i, gene_id in enumerate(gene_ids):
            f.write(gene_id)
            for exp_id in sorted_experiments:
                f.write(f',{final_tpm[exp_id][i]:.6f}')
            f.write('\\n')
    
    # Write log TPM matrix (log2(TPM + 1))
    with open('log_tpm.csv', 'w') as f:
        f.write('GeneID,' + ','.join(sorted_experiments) + '\\n')
        for i, gene_id in enumerate(gene_ids):
            f.write(gene_id)
            for exp_id in sorted_experiments:
                log_tpm = np.log2(final_tpm[exp_id][i] + 1)
                f.write(f',{log_tpm:.6f}')
            f.write('\\n')
    
    print(f"Generated matrices with {len(gene_ids)} genes and {len(sorted_experiments)} experiments")
else:
    print("No data to process - creating empty files")
    with open('counts.csv', 'w') as f:
        f.write('GeneID\\n')
    with open('tpm.csv', 'w') as f:
        f.write('GeneID\\n')
    with open('log_tpm.csv', 'w') as f:
        f.write('GeneID\\n')

EOF
    """
}

//
// Process: MultiQC report
//
process MULTIQC {
    container 'quay.io/biocontainers/multiqc:1.12--pyhdfd78af_0'
    publishDir "${params.outdir}/multiqc", mode: 'copy'
    errorStrategy 'ignore'

    input:
      path qc_files

    output:
      path 'multiqc_report.html', optional: true, emit: html
      path 'multiqc_data.json', optional: true, emit: json

    script:
    """
    echo "Found QC files:"
    ls -la
    
    echo "Running MultiQC..."
    multiqc . -o . --data-format json -v
    
    echo "MultiQC output files:"
    ls -la multiqc*
    
    # Check for JSON in both possible locations
    if [ -f multiqc_data.json ]; then
        echo "MultiQC JSON found in current directory"
        echo "MultiQC JSON size: \$(wc -c < multiqc_data.json) bytes"
        echo "First few lines of JSON:"
        head -n 5 multiqc_data.json
    elif [ -f multiqc_data/multiqc_data.json ]; then
        echo "MultiQC JSON found in multiqc_data directory"
        echo "MultiQC JSON size: \$(wc -c < multiqc_data/multiqc_data.json) bytes"
        echo "First few lines of JSON:"
        head -n 5 multiqc_data/multiqc_data.json
        # Move it to the expected location for the next process
        cp multiqc_data/multiqc_data.json ./multiqc_data.json
        echo "Copied multiqc_data.json to current directory"
    else
        echo "ERROR: multiqc_data.json was not found in current directory or multiqc_data/ subdirectory!"
        echo "Available files:"
        find . -name "*.json" -type f
        exit 1
    fi
    """
}

//
// Process: parse MultiQC JSON to extract samples passing key metrics
process PARSE_QC {
    tag 'parse_multiqc'
    container 'python:3.9-slim'
    errorStrategy 'ignore'

    input:
      path multiqc_json

    output:
      path 'passed_samples.txt', optional: true, emit: passlist
      path 'qc_summary.csv', optional: true, emit: qc_summary
      path 'qc_summary.txt', optional: true, emit: qc_summary_txt

    script:
    """
python3 - << 'EOF'
import json
from pathlib import Path

try:
    data = json.load(open('multiqc_data.json'))
    
    # Find the FastQC raw data with direct pass/fail/warn status
    fastqc_data = None
    
    if ('report_saved_raw_data' in data and 
        'multiqc_fastqc' in data['report_saved_raw_data']):
        fastqc_data = data['report_saved_raw_data']['multiqc_fastqc']
    
    if not fastqc_data:
        # Create empty files for both outputs
        open('passed_samples.txt', 'w').write('')
        # Create empty CSV with headers
        import csv
        with open('qc_summary.csv', 'w', newline='') as csvfile:
            writer = csv.writer(csvfile)
            writer.writerow(['sample', 'per_base_sequence_quality', 'per_sequence_quality_scores', 'per_base_n_content', 'overall_status'])
        # Create summary text file
        with open('qc_summary.txt', 'w') as f:
            f.write("QC Summary Report\\n")
            f.write("=================\\n")
            f.write("Total samples processed: 0\\n")
            f.write("Samples passed: 0\\n")
            f.write("Samples failed: 0\\n")
            f.write("\\nError: No FastQC raw data found in MultiQC JSON\\n")
        exit(0)
    
    # Target metrics we want to extract
    target_metrics = ['per_base_sequence_quality', 'per_sequence_quality_scores', 'per_base_n_content']
    
    # Process each sample and group by experiment ID (SRX, DRX, or ERX)
    experiment_status = {}  # Track status for each experiment
    experiment_samples = {}  # Track which samples belong to each experiment
    qc_results = []
    
    for sample_name, sample_data in fastqc_data.items():
        # Extract experiment ID (everything before the first underscore)
        # This handles SRX_SRR, DRX_DRR, and ERX_ERR patterns
        experiment_id = sample_name.split('_')[0]
        
        # Remove _val_1/_val_2 suffix for paired-end or _trimmed suffix for single-end to get base sample name
        base_sample_name = sample_name.replace('_val_1', '').replace('_val_2', '').replace('_trimmed', '')
        
        ok = True
        failed_metrics = []
        sample_qc = {'sample': sample_name}
        
        # Extract the three critical metrics directly
        for metric in target_metrics:
            status = sample_data.get(metric, 'unknown')
            sample_qc[metric] = status
            
            # If status is not 'pass', mark sample as failed
            if status != 'pass':
                ok = False
                failed_metrics.append(metric)
        
        # Add overall status
        sample_qc['overall_status'] = 'PASS' if ok else 'FAIL'
        qc_results.append(sample_qc)
        
        # Track experiment status - if any sample for an experiment fails, the whole experiment fails
        if experiment_id not in experiment_status:
            experiment_status[experiment_id] = True
            experiment_samples[experiment_id] = set()
        
        experiment_samples[experiment_id].add(base_sample_name)
        
        if not ok:
            experiment_status[experiment_id] = False
    
    # Generate passed sample list (full sample IDs, not just experiment IDs)
    passed_samples = set()
    failed_samples = []
    
    for experiment_id, status in experiment_status.items():
        if status:
            # Add all base sample names for this experiment
            passed_samples.update(experiment_samples[experiment_id])
        else:
            # Find which samples failed for this experiment
            for sample_name, sample_data in fastqc_data.items():
                if sample_name.split('_')[0] == experiment_id:
                    base_sample_name = sample_name.replace('_val_1', '').replace('_val_2', '')
                    failed_metrics = []
                    for metric in target_metrics:
                        status = sample_data.get(metric, 'unknown')
                        if status != 'pass':
                            failed_metrics.append(metric)
                    if failed_metrics:  # Only include samples that actually failed
                        failed_samples.append((sample_name, failed_metrics))
    
    # Write passed sample IDs to file (full sample IDs like SRX_SRR or DRX_DRR)
    with open('passed_samples.txt', 'w') as f:
        for sample_id in sorted(passed_samples):
            f.write(sample_id + '\\n')
    
    # Write QC summary CSV
    import csv
    with open('qc_summary.csv', 'w', newline='') as csvfile:
        fieldnames = ['sample', 'per_base_sequence_quality', 'per_sequence_quality_scores', 'per_base_n_content', 'overall_status']
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
        writer.writeheader()
        
        if qc_results:
            for row in qc_results:
                writer.writerow(row)
    
    # Write QC summary text file
    with open('qc_summary.txt', 'w') as f:
        f.write("QC Summary Report\\n")
        f.write("=================\\n")
        f.write(f"Total individual samples processed: {len(fastqc_data)}\\n")
        f.write(f"Total experiments processed: {len(experiment_status)}\\n")
        f.write(f"Experiments passed: {sum(1 for status in experiment_status.values() if status)}\\n")
        f.write(f"Experiments failed: {sum(1 for status in experiment_status.values() if not status)}\\n")
        f.write(f"Individual samples failed: {len(failed_samples)}\\n")
        f.write(f"Unique sample IDs passed: {len(passed_samples)}\\n")
        
        if failed_samples:
            f.write("\\nFailed individual samples:\\n")
            for sample, metrics in failed_samples:
                f.write(f"  {sample}: {', '.join(metrics)}\\n")
    
except Exception as e:
    import traceback
    # Create empty files to avoid pipeline failure
    open('passed_samples.txt', 'w').write('')
    # Create empty CSV with headers
    import csv
    with open('qc_summary.csv', 'w', newline='') as csvfile:
        writer = csv.writer(csvfile)
        writer.writerow(['sample', 'per_base_sequence_quality', 'per_sequence_quality_scores', 'per_base_n_content', 'overall_status'])
    # Create error summary text file
    with open('qc_summary.txt', 'w') as f:
        f.write("QC Summary Report\\n")
        f.write("=================\\n")
        f.write("Total samples processed: 0\\n")
        f.write("Samples passed: 0\\n")
        f.write("Samples failed: 0\\n")
        f.write(f"\\nError processing MultiQC data: {e}\\n")
        f.write(f"Traceback: {traceback.format_exc()}\\n")
EOF
    """
}

//
// Process: filter sample sheet CSV based on passed samples
process FILTER_SAMPLESHEET {
    tag 'filter_samplesheet'
    container 'ubuntu:22.04'
    publishDir "${params.outdir}/samplesheet", mode: 'copy', overwrite: true
    errorStrategy 'ignore'

    input:
      path samplesheet
      path passedlist

    output:
      path 'samplesheet.csv', optional: true

    script:
    """
    # Copy original samplesheet and remove empty lines
    grep -v '^[[:space:]]*\$' ${samplesheet} > tmp.csv
    
    # Check if passed samples file is empty
    if [ ! -s ${passedlist} ]; then
        echo "WARNING: No samples passed QC filters!"
        # Create samplesheet with only header
        head -n1 tmp.csv > samplesheet.csv
    else
        # Copy header
        head -n1 tmp.csv > samplesheet.csv
        
        # Filter rows based on passed sample IDs
        # First, find which column contains 'id' in the header
        id_col=\$(head -n1 tmp.csv | tr ',' '\n' | grep -n '^"\\?id"\\?\$' | cut -d: -f1)
        
        if [ -z "\$id_col" ]; then
            echo "ERROR: Could not find 'id' column in samplesheet"
            exit 1
        fi
        
        while IFS= read -r sample_id; do
            if [ -n "\$sample_id" ]; then
                # Look for lines where the id column matches the sample ID exactly
                # Use awk to properly parse CSV and check the id column dynamically
                awk -F',' -v col="\$id_col" -v sample="\$sample_id" '
                    NR > 1 && \$col == "\\"" sample "\\"" { print }
                ' tmp.csv >> samplesheet.csv || true
            fi
        done < ${passedlist}
        
        # Remove duplicates while preserving order
        awk '!seen[\$0]++' samplesheet.csv > samplesheet_dedup.csv
        mv samplesheet_dedup.csv samplesheet.csv
    fi
    
    # Report results
    original_count=\$(tail -n +2 tmp.csv | grep -c '^')
    filtered_count=\$(tail -n +2 samplesheet.csv | grep -c '^')
    echo "Original samples: \$original_count"
    echo "Filtered samples: \$filtered_count"
    echo "Samples removed: \$((\$original_count - \$filtered_count))"
    """
}

//
// Process: filter out samples with >50% zero values from expression matrices and samplesheet
//
process FILTER_LOW_EXPRESSION_SAMPLES {
    tag 'filter_low_expression'
    container 'felixlohmeier/pandas:1.3.3'
    publishDir "${params.outdir}/expression_matrices", mode: 'copy', overwrite: true, pattern: "{tpm.csv,log_tpm.csv,counts.csv}"
    publishDir "${params.outdir}/samplesheet", mode: 'copy', overwrite: true, pattern: "samplesheet.csv"
    errorStrategy 'ignore'

    input:
      path tpm_matrix
      path log_tpm_matrix  
      path counts_matrix
      path samplesheet

    output:
      path 'tpm.csv', optional: true, emit: tpm
      path 'log_tpm.csv', optional: true, emit: log_tpm
      path 'counts.csv', optional: true, emit: counts
      path 'samplesheet.csv', optional: true, emit: samplesheet

    script:
    """
    python3 - << 'EOF'
import pandas as pd
import numpy as np

print("Reading expression matrices...")
# Read the three expression matrices
tpm_df = pd.read_csv('${tpm_matrix}', index_col=0)
log_tpm_df = pd.read_csv('${log_tpm_matrix}', index_col=0)
counts_df = pd.read_csv('${counts_matrix}', index_col=0)

print(f"Original matrices shape: {tpm_df.shape}")
print(f"Sample columns: {list(tpm_df.columns)}")

# Identify samples with >50% zero values
samples_to_remove = []
total_genes = len(tpm_df)

for sample in tpm_df.columns:
    # Count zeros in the counts matrix (most appropriate for this analysis)
    zero_count = (counts_df[sample] == 0).sum()
    zero_percentage = zero_count / total_genes
    
    print(f"Sample {sample}: {zero_count}/{total_genes} zeros ({zero_percentage:.2%})")
    
    if zero_percentage > 0.5:
        samples_to_remove.append(sample)
        print(f"  -> Will be removed (>50% zeros)")

print(f"\\nSamples to remove ({len(samples_to_remove)}): {samples_to_remove}")

# Filter matrices by removing low-expression samples
if samples_to_remove:
    samples_to_keep = [col for col in tpm_df.columns if col not in samples_to_remove]
    
    tpm_filtered = tpm_df[samples_to_keep]
    log_tpm_filtered = log_tpm_df[samples_to_keep]
    counts_filtered = counts_df[samples_to_keep]
    
    print(f"Filtered matrices shape: {tpm_filtered.shape}")
else:
    print("No samples need to be removed")
    tpm_filtered = tpm_df
    log_tpm_filtered = log_tpm_df  
    counts_filtered = counts_df

# Save filtered matrices (overwrite originals)
tpm_filtered.to_csv('tpm.csv')
log_tpm_filtered.to_csv('log_tpm.csv')
counts_filtered.to_csv('counts.csv')

print("Reading and filtering samplesheet...")
# Read and filter samplesheet with robust CSV parsing
try:
    # First try standard parsing
    samplesheet_df = pd.read_csv('${samplesheet}')
except pd.errors.ParserError as e:
    print(f"CSV parsing error: {e}")
    print("Attempting to fix CSV parsing issues...")
    # Try with different parsing options to handle malformed CSV
    try:
        # Try with quoting to handle embedded quotes
        samplesheet_df = pd.read_csv('${samplesheet}', quotechar='"', skipinitialspace=True)
    except:
        try:
            # Try with python engine and different quoting
            samplesheet_df = pd.read_csv('${samplesheet}', engine='python', quotechar='"', skipinitialspace=True)
        except:
            # Last resort: read line by line and fix manually
            import csv
            print("Reading CSV manually to handle parsing errors...")
            rows = []
            with open('${samplesheet}', 'r') as f:
                header = f.readline().strip().split(',')
                expected_cols = len(header)
                # Clean header
                header = [col.strip('"') for col in header]
                print(f"Expected {expected_cols} columns: {header}")
                
                for line_num, line in enumerate(f, start=2):
                    line = line.strip()
                    if not line:
                        continue
                    
                    # Simple CSV parsing that handles malformed quotes
                    fields = []
                    in_quotes = False
                    current_field = ""
                    i = 0
                    while i < len(line):
                        char = line[i]
                        if char == '"':
                            if in_quotes and i + 1 < len(line) and line[i + 1] == '"':
                                # Escaped quote
                                current_field += '"'
                                i += 2
                                continue
                            else:
                                in_quotes = not in_quotes
                        elif char == ',' and not in_quotes:
                            fields.append(current_field.strip('"'))
                            current_field = ""
                            i += 1
                            continue
                        else:
                            current_field += char
                        i += 1
                    
                    # Add the last field
                    fields.append(current_field.strip('"'))
                    
                    # Handle field count mismatch
                    if len(fields) == expected_cols:
                        rows.append(fields)
                    elif len(fields) > expected_cols:
                        print(f"Line {line_num}: Found {len(fields)} fields, merging extras")
                        # Merge extra fields into the last column
                        fixed_row = fields[:expected_cols-1] + [','.join(fields[expected_cols-1:])]
                        rows.append(fixed_row)
                    else:
                        print(f"Line {line_num}: Found {len(fields)} fields, padding with empty values")
                        padded_row = fields + [''] * (expected_cols - len(fields))
                        rows.append(padded_row)
            
            samplesheet_df = pd.DataFrame(rows, columns=header)

print(f"Original samplesheet shape: {samplesheet_df.shape}")

if samples_to_remove:
    # Filter samplesheet by removing rows where 'id' column matches samples to remove
    # The sample ID in the matrix corresponds to the 'id' column in samplesheet
    samplesheet_filtered = samplesheet_df[~samplesheet_df['id'].isin(samples_to_remove)]
    print(f"Filtered samplesheet shape: {samplesheet_filtered.shape}")
    print(f"Removed {len(samplesheet_df) - len(samplesheet_filtered)} rows from samplesheet")
else:
    samplesheet_filtered = samplesheet_df

# Save filtered samplesheet (overwrite original)
samplesheet_filtered.to_csv('samplesheet.csv', index=False)

print("\\nFiltering completed successfully!")
print(f"Final matrices have {len(tpm_filtered.columns)} samples and {len(tpm_filtered)} genes")

EOF
    """
}

//
// Process: normalize log TPM data
//
process NORMALIZE_LOG_TPM {
    tag 'normalize_log_tpm'
    container 'felixlohmeier/pandas:1.3.3'
    publishDir "${params.outdir}/expression_matrices", mode: 'copy'
    errorStrategy 'ignore'

    input:
      path log_tpm_csv

    output:
      path 'log_tpm_norm.csv', optional: true

    script:
    """
    python3 - << 'EOF'
import pandas as pd

def normalize_csv(csv_path_in: str, csv_path_out: str):
    # Normalize a CSV file by subtracting the row-wise mean of all
    # numeric columns (excluding the first, GeneID) from every numeric value in
    # that row. Rows that become entirely zero are removed.

    # Parameters
    # ----------
    # csv_path_in : str
    #     Path to the input CSV file.
    # csv_path_out : str
    #     Path to save the output CSV file.

    # Read the CSV
    df = pd.read_csv(csv_path_in)
    input_rows = len(df)                      # header not included

    # Separate the GeneID column
    gene_col = df.iloc[:, 0]

    # Numeric data (everything except the first column)
    numeric_data = df.iloc[:, 1:]

    # Subtract the row mean from each numeric value
    row_mean = numeric_data.mean(axis=1)
    adjusted_numeric = numeric_data.sub(row_mean, axis=0)

    # Remove rows where all adjusted numeric values are zero
    keep_mask = ~adjusted_numeric.eq(0).all(axis=1)
    adjusted_numeric = adjusted_numeric[keep_mask]
    gene_col = gene_col[keep_mask]

    # Reattach the GeneID column
    df_final = pd.concat([gene_col, adjusted_numeric], axis=1)
    final_rows = len(df_final)

    # Save to CSV
    df_final.to_csv(csv_path_out, index=False)

# Process the log TPM file
normalize_csv('${log_tpm_csv}', 'log_tpm_norm.csv')
EOF
    """
}

//
// Process: Validate data consistency and fix gene ID prefixes
// This ensures the 'sample' column in samplesheet matches the column names in expression matrices
// Also removes 'gene-' prefix from gene IDs if present
//
process DATA_VALIDATION {
    tag 'data_validation'
    container 'felixlohmeier/pandas:1.3.3'
    publishDir "${params.outdir}/samplesheet", mode: 'copy', overwrite: true, pattern: "{samplesheet.csv,samplesheet_download.csv}"
    publishDir "${params.outdir}/expression_matrices", mode: 'copy', overwrite: true, pattern: "{tpm.csv,log_tpm.csv,counts.csv,log_tpm_norm.csv}"
    errorStrategy 'terminate'

    input:
      path samplesheet
      path tpm_matrix
      path log_tpm_matrix
      path counts_matrix
      path log_tpm_norm_matrix
      path samplesheet_download_file, stageAs: 'samplesheet_download_orig.csv'

    output:
      path 'samplesheet.csv', emit: samplesheet
      path 'samplesheet_download.csv', emit: samplesheet_download, optional: true
      path 'tpm.csv', emit: tpm
      path 'log_tpm.csv', emit: log_tpm
      path 'counts.csv', emit: counts
      path 'log_tpm_norm.csv', emit: log_tpm_norm

    script:
    """
    python3 - << 'EOF'
import pandas as pd
import sys
import os

print("=== DATA_VALIDATION ===")
print("Ensuring samplesheet 'sample' column matches expression matrix columns exactly...")
print("Also checking and fixing gene ID prefixes...")

# First, process samplesheet_download.csv if it exists. Read from the file Nextflow
# staged into this task's working directory (declared as an input above) rather than
# a raw params.outdir path -- the raw path only resolves for a local filesystem outdir,
# not an s3:// one.
samplesheet_download_path = "samplesheet_download_orig.csv"
if os.path.exists(samplesheet_download_path):
    print("\\n=== PROCESSING SAMPLESHEET_DOWNLOAD.CSV ===")
    try:
        download_df = pd.read_csv(samplesheet_download_path)
        print(f"Original samplesheet_download.csv: {len(download_df)} rows")
        
        if 'id' in download_df.columns:
            # Extract experiment ID (everything before first underscore)
            download_df['experiment_id'] = download_df['id'].str.split('_').str[0]
            
            # Check for duplicates
            duplicates = download_df[download_df.duplicated(subset=['experiment_id'], keep=False)]
            if len(duplicates) > 0:
                print(f"Found {download_df['experiment_id'].nunique()} unique experiments from {len(download_df)} rows")
                
                # Columns that should be concatenated with semicolons when merging
                concat_columns = ['run_accession', 'id', 'fastq_1', 'fastq_2', 'fastq_md5', 
                                  'fastq_bytes', 'fastq_ftp', 'fastq_galaxy', 'fastq_aspera',
                                  'run_alias', 'base_count', 'read_count']
                
                # Group by experiment_id and merge
                merged_rows = []
                grouped = download_df.groupby('experiment_id')
                
                for exp_id, group in grouped:
                    if len(group) == 1:
                        row = group.iloc[0].to_dict()
                        # Use experiment_id as the new id
                        row['id'] = exp_id
                        merged_rows.append(row)
                    else:
                        # Merge duplicate rows
                        merged_row = {'id': exp_id, 'experiment_id': exp_id}
                        for col in download_df.columns:
                            if col in ['id', 'experiment_id']:
                                continue  # Already set above
                            elif col in concat_columns:
                                # Concatenate these columns with semicolon
                                values = group[col].dropna().astype(str).tolist()
                                merged_row[col] = ';'.join(values) if values else ''
                            else:
                                # For other columns, take the first non-null value
                                non_null_values = group[col].dropna()
                                if len(non_null_values) > 0:
                                    merged_row[col] = non_null_values.iloc[0]
                                else:
                                    merged_row[col] = ''
                        merged_rows.append(merged_row)
                
                download_df = pd.DataFrame(merged_rows)
                # Remove the experiment_id column as it's now redundant with id
                if 'experiment_id' in download_df.columns:
                    download_df = download_df.drop('experiment_id', axis=1)
                print(f"After merging by experiment: {len(download_df)} rows")
            else:
                # No duplicates, just update id to be experiment_id
                download_df['id'] = download_df['experiment_id']
                download_df = download_df.drop('experiment_id', axis=1)
                print("No duplicate experiments found")
            
            # Save the merged samplesheet_download.csv
            download_df.to_csv('samplesheet_download.csv', index=False)
            print("Updated samplesheet_download.csv with merged experiments")
        else:
            print("ERROR: 'id' column not found in samplesheet_download.csv")
            # Just copy the original file
            import shutil
            shutil.copy(samplesheet_download_path, 'samplesheet_download.csv')
            
    except Exception as e:
        print(f"ERROR processing samplesheet_download.csv: {e}")
        # Copy original file on error
        import shutil
        if os.path.exists(samplesheet_download_path):
            shutil.copy(samplesheet_download_path, 'samplesheet_download.csv')

# Read expression matrices to get column names
print("\\nReading expression matrices...")
matrix_files = {
    'counts.csv': '${counts_matrix}',
    'tpm.csv': '${tpm_matrix}',
    'log_tpm.csv': '${log_tpm_matrix}',
    'log_tpm_norm.csv': '${log_tpm_norm_matrix}'
}

matrix_columns = {}
for matrix_name, matrix_file in matrix_files.items():
    df = pd.read_csv(matrix_file, index_col=0)
    matrix_columns[matrix_name] = list(df.columns)
    print(f"  {matrix_name}: {len(df.columns)} samples")

# Check if all matrices have the same columns
all_columns = list(matrix_columns.values())
reference_cols = all_columns[0]

if len(all_columns) > 1:
    matrices_consistent = all(cols == reference_cols for cols in all_columns[1:])
    if not matrices_consistent:
        print("ERROR: Expression matrices have inconsistent columns!")
        sys.exit(1)

expression_samples = set(reference_cols)
expression_samples_ordered = reference_cols
print(f"\\nExpression matrices: {len(expression_samples)} samples found")

# Read samplesheet
print("\\nReading samplesheet...")
samplesheet_df = pd.read_csv('${samplesheet}')
print(f"Original samplesheet: {len(samplesheet_df)} rows")

# Find sample ID column - prioritize 'sample' column, then try other common names
sample_col = None
if 'sample' in samplesheet_df.columns:
    sample_col = 'sample'
else:
    for col in ['Sample', 'experiment_accession', 'sample_id', 'Sample_ID', 'id']:
        if col in samplesheet_df.columns:
            sample_col = col
            break

if sample_col is None:
    print("ERROR: Could not identify sample ID column in samplesheet")
    print(f"Available columns: {list(samplesheet_df.columns)}")
    sys.exit(1)

print(f"Using column '{sample_col}' as sample ID")

# Merge duplicate samples (multiple runs for same experiment)
print("\\nChecking for duplicate samples...")
duplicates = samplesheet_df[samplesheet_df.duplicated(subset=[sample_col], keep=False)]
if len(duplicates) > 0:
    print(f"Found {samplesheet_df[sample_col].nunique()} unique samples from {len(samplesheet_df)} rows")
    
    # Columns that should be concatenated with semicolons when merging
    concat_columns = ['run_accession', 'id', 'fastq_1', 'fastq_2', 'fastq_md5', 
                      'fastq_bytes', 'fastq_ftp', 'fastq_galaxy', 'fastq_aspera',
                      'run_alias', 'base_count', 'read_count']
    
    # Group by sample column and merge
    merged_rows = []
    grouped = samplesheet_df.groupby(sample_col)
    
    for sample_id, group in grouped:
        if len(group) == 1:
            merged_rows.append(group.iloc[0].to_dict())
        else:
            # Merge duplicate rows
            merged_row = {}
            for col in samplesheet_df.columns:
                if col in concat_columns:
                    # Concatenate these columns with semicolon
                    values = group[col].dropna().astype(str).tolist()
                    merged_row[col] = ';'.join(values) if values else ''
                else:
                    # For other columns, take the first non-null value
                    non_null_values = group[col].dropna()
                    if len(non_null_values) > 0:
                        merged_row[col] = non_null_values.iloc[0]
                    else:
                        merged_row[col] = ''
            merged_rows.append(merged_row)
    
    samplesheet_df = pd.DataFrame(merged_rows)
    print(f"After merging: {len(samplesheet_df)} rows")

# Get current samples in samplesheet
samplesheet_samples = set(samplesheet_df[sample_col].astype(str).unique())

# Check what needs to be updated
samples_to_keep = samplesheet_samples.intersection(expression_samples)
samples_to_remove = samplesheet_samples - expression_samples
missing_samples = expression_samples - samplesheet_samples

print(f"\\nAnalysis:")
print(f"  - Samples in both: {len(samples_to_keep)}")
print(f"  - Samples to remove from samplesheet: {len(samples_to_remove)}")
print(f"  - Samples missing from samplesheet: {len(missing_samples)}")

# Filter samplesheet to keep only samples in expression matrix
filtered_samplesheet = samplesheet_df[samplesheet_df[sample_col].astype(str).isin(expression_samples)]

# If the sample column is not named 'sample', rename it
if sample_col != 'sample':
    filtered_samplesheet = filtered_samplesheet.rename(columns={sample_col: 'sample'})
    print(f"\\nRenamed column '{sample_col}' to 'sample'")

# Ensure column order makes sense (sample column first)
cols = filtered_samplesheet.columns.tolist()
if 'sample' in cols:
    cols.remove('sample')
    cols = ['sample'] + cols
    filtered_samplesheet = filtered_samplesheet[cols]

# Save updated samplesheet
filtered_samplesheet.to_csv('samplesheet.csv', index=False)
print(f"\\nUpdated samplesheet: {len(samplesheet_df)} → {len(filtered_samplesheet)} rows")

# Process expression matrices - check for 'gene-' prefix and remove if present
print("\\n=== PROCESSING GENE IDs ===")
for matrix_name in matrix_files.keys():
    df = pd.read_csv(matrix_files[matrix_name], index_col=0)
    
    # Check if gene IDs start with 'gene-'
    if df.index[0].startswith('gene-'):
        print(f"{matrix_name}: Found 'gene-' prefix in gene IDs, removing...")
        # Remove 'gene-' prefix from all gene IDs
        df.index = df.index.str.replace('^gene-', '', regex=True)
        print(f"  Example: gene-WMS_00296 → WMS_00296")
    else:
        print(f"{matrix_name}: No 'gene-' prefix found in gene IDs")
    
    # Save the processed matrix
    df.to_csv(matrix_name)

# Final verification
print("\\n=== FINAL VERIFICATION ===")
final_samplesheet_samples = set(filtered_samplesheet['sample'].astype(str).unique())
matrix_samples = set(reference_cols)

if final_samplesheet_samples == matrix_samples:
    print("✅ SUCCESS: Samplesheet 'sample' column now matches expression matrix columns exactly!")
    print(f"   Both contain {len(matrix_samples)} samples")
else:
    # This should not happen, but check anyway
    in_samplesheet_not_matrix = final_samplesheet_samples - matrix_samples
    in_matrix_not_samplesheet = matrix_samples - final_samplesheet_samples
    
    if in_samplesheet_not_matrix:
        print(f"❌ ERROR: {len(in_samplesheet_not_matrix)} samples in samplesheet but not in matrices")
    if in_matrix_not_samplesheet:
        print(f"❌ ERROR: {len(in_matrix_not_samplesheet)} samples in matrices but not in samplesheet")
        if len(in_matrix_not_samplesheet) <= 10:
            print(f"   Missing samples: {sorted(in_matrix_not_samplesheet)}")
    sys.exit(1)

EOF
    """
}

//
// Main workflow
//
workflow {
    // load samples from the original download samplesheet
    samples_ch = Channel
        .fromPath( file("${params.outdir}/samplesheet/samplesheet_download.csv") )
        .ifEmpty { error "Sample sheet not found at: ${params.outdir}/samplesheet/samplesheet_download.csv" }
        .splitCsv(header: true, sep: ',')
        // remove surrounding quotes and normalize keys
        .map { row ->
            row.collectEntries { k, v ->
                def key   = k.trim().toLowerCase().replaceAll(/^"|"$/, '')
                def value = v?.toString()?.trim()?.replaceAll(/^"|"$/, '')
                [ key, value ]
            }
        }
        // keep only rows that have all required fields
        .filter { row ->
            row.id && row.fastq_1 && row.run_accession
        }
        .ifEmpty {
            error """
    No valid samples found after filtering.
    Make sure your CSV has columns exactly named:
    id, fastq_1, run_accession.
    """
        }
        // build the tuple for each sample using the id column which has SRX_SRR, DRX_DRR, or ERX_ERR format
        .map { row ->
            def reads = [file("${params.outdir}/${row.fastq_1}")]
            if (row.fastq_2 && row.fastq_2.trim()) {
                reads.add(file("${params.outdir}/${row.fastq_2}"))
            }
            tuple(row.id, reads)
        }

    // build index
    cds_fa_ch       = EXTRACT_CDS( file(params.ref_genome), file(params.ref_gff) )
    salmon_index_ch = SALMON_INDEX(cds_fa_ch)

    // trim
    trimmed_ch = TRIMGALORE(samples_ch)

    // Filter successful TRIMGALORE outputs - robust filtering
    trimmed_success_ch = trimmed_ch
        .filter { sample, reads ->
            // Check if we have valid reads output
            if (!reads) {
                println "Sample ${sample}: No output from TRIMGALORE - filtering out"
                return false
            }
            // Handle case where reads is a collection/list
            if (reads instanceof Collection) {
                def readsList = reads.toList()
                if (readsList.isEmpty()) {
                    println "Sample ${sample}: Empty reads collection from TRIMGALORE - filtering out"
                    return false
                }
                // Check if all elements are valid files
                def validFiles = readsList.findAll { it && it.exists() }
                if (validFiles.isEmpty()) {
                    println "Sample ${sample}: No valid files in reads collection - filtering out"
                    return false
                }
            }
            return true
        }

    // QC trimmed reads - more robust handling
    qc_ch = FASTQC(
        trimmed_success_ch
            .map { sample, reads ->
                // Check for valid sample name first
                if (!sample || sample == "null" || sample.toString().trim().isEmpty()) {
                    println "Warning: Invalid sample name '${sample}' - skipping FASTQC"
                    return null
                }
                
                // Ensure we have valid file paths for FASTQC
                if (!reads) {
                    println "Warning: No reads for sample ${sample} - skipping FASTQC"
                    return null
                }
                
                // Convert to list if needed
                def readsList = reads instanceof Collection ? reads.toList() : [reads]
                
                // Filter out any null or non-existent files
                def validReads = readsList.findAll { it && it.exists() }
                
                if (validReads.isEmpty()) {
                    println "Warning: No valid read files for sample ${sample} - skipping FASTQC"
                    return null
                }
                
                // FASTQC expects (sample, fq1, fq2) where fq2 can be null
                def fq1 = validReads[0]
                def fq2 = validReads.size() > 1 ? validReads[1] : null
                
                // Create a null file placeholder for fq2 if it doesn't exist
                if (!fq2) {
                    // Use a special marker to indicate single-end
                    fq2 = file('/dev/null')
                }
                
                tuple(sample, fq1, fq2)
            }
            .filter { it != null }  // Remove any null entries
            .filter { sample, fq1, fq2 -> sample && sample != "null" }  // Double-check sample names
    )

    // Filter successful FASTQC outputs
    qc_success_ch = qc_ch
        .filter { files ->
            // With optional: true, empty outputs return empty collection
            files != null && !files.isEmpty()
        }

    // MultiQC on trimmed QC results - only successful ones, filter out null-named files
    multiqc = MULTIQC( 
        qc_success_ch
            .collect()
            .map { files ->
                // Filter out any files with 'null' in the name
                files.findAll { file ->
                    !file.getName().contains('null')
                }
            }
    )
    multiqc_json_ch = multiqc.json
        .filter { it != null }
        .ifEmpty { 
            // Create empty JSON file if MultiQC fails
            file("${params.outdir}/multiqc/empty_multiqc.json").text = '{}'
            file("${params.outdir}/multiqc/empty_multiqc.json")
        }
    
    // Parse MultiQC JSON for passed samples
    parse_qc_result = PARSE_QC( multiqc_json_ch )
    passed_ch = parse_qc_result.passlist
        .filter { it != null }
        .ifEmpty { 
            // Create empty passlist if parsing fails
            file("${params.outdir}/multiqc/empty_passlist.txt").text = ''
            file("${params.outdir}/multiqc/empty_passlist.txt")
        }
    qc_summary_ch = parse_qc_result.qc_summary
        .filter { it != null }
    qc_summary_txt_ch = parse_qc_result.qc_summary_txt
        .filter { it != null }

    // Copy QC summary files to multiqc folder if they exist
    qc_summary_ch.subscribe { qc_file ->
        if (qc_file && qc_file.exists()) {
            def target_dir = file("${params.outdir}/multiqc")
            target_dir.mkdirs()
            qc_file.copyTo(target_dir.resolve("qc_summary.csv"))
        }
    }
    
    qc_summary_txt_ch.subscribe { qc_file ->
        if (qc_file && qc_file.exists()) {
            def target_dir = file("${params.outdir}/multiqc")
            target_dir.mkdirs()
            qc_file.copyTo(target_dir.resolve("qc_summary.txt"))
        }
    }

    // Filter original sample sheet based on passed samples
    filtered_samplesheet_ch = FILTER_SAMPLESHEET( file("${params.outdir}/samplesheet/samplesheet_download.csv"), passed_ch )

    // Create a channel of passed sample IDs
    passed_samples_ch = passed_ch
        .splitText()
        .map { it.trim() }
        .filter { it }
        .map { sample_id -> tuple(sample_id, sample_id) }

    // Transform trimmed channel to include sample ID as key - use only successful samples
    trimmed_with_sample_ch = trimmed_success_ch
        .map { sample_tuple ->
            def sample_id = sample_tuple[0]
            // Remove _val_1/_val_2 suffixes for paired-end or _trimmed for single-end to get base sample name
            def base_sample_id = sample_id.replace('_val_1', '').replace('_val_2', '').replace('_trimmed', '')
            tuple(base_sample_id, sample_tuple)
        }

    // Join to filter only QC-passed samples
    filtered_trimmed_ch = trimmed_with_sample_ch
        .join(passed_samples_ch)
        .map { base_sample_id, sample_tuple, passed_sample -> sample_tuple }

    // Run Salmon quantification only on QC-passed samples
    quant_ch = SALMON_QUANT(filtered_trimmed_ch, salmon_index_ch)

    // Filter successful Salmon outputs
    quant_success_ch = quant_ch
        .filter { quant_dir ->
            quant_dir != null
        }

    // merge count matrices - wait for both quantification and samplesheet filtering
    count_matrix_ch = MERGE_COUNTS( 
        quant_success_ch.collect(), 
        passed_ch
    )

    // Filter out samples with >50% zero values from expression matrices and samplesheet
    filtered_results = FILTER_LOW_EXPRESSION_SAMPLES(
        count_matrix_ch[0],  // tpm.csv
        count_matrix_ch[1],  // log_tpm.csv  
        count_matrix_ch[2],  // counts.csv
        filtered_samplesheet_ch
    )

    // Normalize log TPM data if available
    log_tpm_norm_ch = NORMALIZE_LOG_TPM(filtered_results.log_tpm)
    
    // Validate and ensure samplesheet matches expression matrices exactly
    // Also remove 'gene-' prefix from gene IDs if present
    validated_results = DATA_VALIDATION(
        filtered_results.samplesheet,
        filtered_results.tpm,
        filtered_results.log_tpm,
        filtered_results.counts,
        log_tpm_norm_ch,
        file("${params.outdir}/samplesheet/samplesheet_download.csv")
    )
}

// Add an onComplete event handler to always delete rotated Nextflow log files
workflow.onComplete {
    def logPattern = ~/\.nextflow\.log\.\d+/  
    new File('.').listFiles().findAll { it.name ==~ logPattern }.each { it.delete() }
}