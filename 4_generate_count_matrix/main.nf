//
// Required parameters
//
params.outdir    = null
params.cpu = params.cpu ?: 20

// --quantifier selects the gene-quantification method:
//   'bowtie2' (default) -- Bowtie2 aligns reads to the whole genome, then
//     featureCounts assigns them to every gene type in the GFF (protein-coding,
//     tRNA, rRNA, ncRNA -- anything with a 'gene' feature), not just CDS. This
//     gives visibility into non-coding-RNA read fraction that the CDS-only
//     path structurally cannot see (see 4_generate_count_matrix/README.md).
//   'salmon' -- the original CDS-only pseudo-alignment path (EXTRACT_CDS +
//     SALMON_INDEX + SALMON_QUANT), kept as an opt-in.
params.quantifier = params.quantifier ?: 'bowtie2'

// Note: the --outdir requiredness check and the reference-genome/GFF auto-detection
// that used to live here (as top-level `if`/`def` statements) now live at the top of
// workflow{} below instead -- Nextflow (26.x+) rejects bare statements mixed with
// script declarations (process/workflow definitions) at the top level of the script.
// threads_per_task (always 4) and max_parallel (params.cpu/4) are inlined directly into
// each process's cpus/maxForks directives below for the same reason, rather than kept as
// shared top-level variables.

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
    cpus 4
    // Plain expression, not a maxForks { ... } closure -- unlike cpus/memory/
    // errorStrategy, maxForks doesn't evaluate a closure's return value here; it compares
    // the closure object itself against an Integer, crashing with "Cannot compare
    // Main$_runScript_closure... with ... java.lang.Integer" the instant the process is
    // invoked. params.cpu is already fully resolved by the time processes are defined, so
    // a plain expression (evaluated once, like sibling modules' `maxForks params.x ?: y`)
    // works fine and needs no per-task re-evaluation anyway.
    // Also needs an explicit `as Integer` cast on params.cpu itself: CLI-supplied params
    // (--cpu 8) arrive as Strings, and Groovy Strings don't support `/` -- fails with
    // "Unknown method invocation `div` on String type" the moment this is evaluated
    // eagerly (masked before by the closure never actually being invoked).
    maxForks( (params.cpu as Integer).intdiv(4) )
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
    cpus 4
    maxForks( (params.cpu as Integer).intdiv(4) )
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
    cpus 4
    maxForks( (params.cpu as Integer).intdiv(4) )
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
// Process: build Bowtie2 index from the whole reference genome (not CDS-only)
//
process BOWTIE2_BUILD {
    tag 'bowtie2_build'
    container 'quay.io/biocontainers/bowtie2:2.5.5--ha27dd3b_0'
    errorStrategy 'ignore'

    input:
      path genome

    output:
      path 'bowtie2_index', optional: true

    script:
    """
    mkdir -p bowtie2_index
    bowtie2-build --threads 2 ${genome} bowtie2_index/index
    """
}

//
// Process: align trimmed reads to the whole genome with Bowtie2
//
process BOWTIE2_ALIGN {
    tag '$sample'
    container 'quay.io/biocontainers/bowtie2:2.5.5--ha27dd3b_0'
    cpus 2
    maxForks( (params.cpu as Integer).intdiv(4) )
    errorStrategy 'ignore'

    input:
      tuple val(sample), path(reads)
      path index

    output:
      tuple val(sample), path("${sample}.sam"), val(reads instanceof List && reads.size() == 2), optional: true, emit: sam

    script:
    def is_paired = reads instanceof List && reads.size() == 2
    if (is_paired) {
        """
        bowtie2 -x ${index}/index -1 ${reads[0]} -2 ${reads[1]} -p 2 -S ${sample}.sam || true
        if [ ! -s ${sample}.sam ]; then
            echo "BOWTIE2_ALIGN failed for sample ${sample}" >&2
        fi
        """
    } else {
        def read_file = reads instanceof List ? reads[0] : reads
        """
        bowtie2 -x ${index}/index -U ${read_file} -p 2 -S ${sample}.sam || true
        if [ ! -s ${sample}.sam ]; then
            echo "BOWTIE2_ALIGN failed for sample ${sample}" >&2
        fi
        """
    }
}

//
// Process: coordinate-sort and index the Bowtie2 alignments
//
process SAM_SORT_INDEX {
    tag '$sample'
    container 'quay.io/biocontainers/samtools:1.24--h9dcdb79_1'
    publishDir "${params.outdir}/bowtie2", mode: 'copy'
    cpus 2
    errorStrategy 'ignore'

    input:
      tuple val(sample), path(sam), val(is_paired)

    output:
      tuple val(sample), path("${sample}.sorted.bam"), val(is_paired), optional: true, emit: bam
      path "${sample}.sorted.bam.bai", optional: true, emit: bai

    script:
    """
    samtools sort -@ 2 -o ${sample}.sorted.bam ${sam}
    samtools index ${sample}.sorted.bam
    """
}

//
// Process: assign aligned reads to genes -- every 'gene' feature in the GFF
// (protein-coding, tRNA, rRNA, ncRNA), not just CDS -- grouped by locus_tag.
//
process FEATURECOUNTS {
    tag '$sample'
    container 'quay.io/biocontainers/subread:2.1.1--h577a1d6_0'
    publishDir "${params.outdir}/featurecounts", mode: 'copy'
    cpus 2
    errorStrategy 'ignore'

    input:
      tuple val(sample), path(bam), val(is_paired)
      path annotation

    output:
      path "${sample}_counts.txt", optional: true, emit: counts

    script:
    def pairFlag = is_paired ? '-p --countReadPairs' : ''
    """
    featureCounts -a ${annotation} -F GTF -t gene -g locus_tag ${pairFlag} -T 2 -o ${sample}_counts.txt ${bam}
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
    merge_salmon_counts.py --passed-samples-file ${passed_samples_file}
    """
}

//
// Process: merge featureCounts outputs by experiment ID (Bowtie2 path's
// counterpart to MERGE_COUNTS -- same experiment-grouping/TPM logic, reading
// featureCounts' "<sample>_counts.txt" format instead of Salmon's quant.sf)
//
process MERGE_COUNTS_FEATURECOUNTS {
    publishDir "${params.outdir}/expression_matrices", mode: 'copy'
    container 'felixlohmeier/pandas:1.3.3'
    errorStrategy 'ignore'

    input:
      path count_files
      path passed_samples_file

    output:
      path 'tpm.csv', optional: true
      path 'log_tpm.csv', optional: true
      path 'counts.csv', optional: true

    script:
    """
    merge_featurecounts.py --passed-samples-file ${passed_samples_file}
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
    parse_qc.py --multiqc-json multiqc_data.json
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
                # Look for lines where the id column matches the sample ID exactly.
                # Strip a leading/trailing double-quote from the field before comparing,
                # so this matches regardless of whether the CSV quotes its id values
                # (mirrors the id_col detection above, which already tolerates both).
                awk -F',' -v col="\$id_col" -v sample="\$sample_id" '
                    NR > 1 { val = \$col; gsub(/^"|"\$/, "", val); if (val == sample) print }
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
    filter_low_expression_samples.py \
      --tpm ${tpm_matrix} \
      --log-tpm ${log_tpm_matrix} \
      --counts ${counts_matrix} \
      --samplesheet ${samplesheet}
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
    normalize_log_tpm.py --log-tpm ${log_tpm_csv} --output log_tpm_norm.csv
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
    data_validation.py \
      --samplesheet ${samplesheet} \
      --tpm ${tpm_matrix} \
      --log-tpm ${log_tpm_matrix} \
      --counts ${counts_matrix} \
      --log-tpm-norm ${log_tpm_norm_matrix} \
      --samplesheet-download samplesheet_download_orig.csv
    """
}

//
// Main workflow
//
workflow {
    // Registered here, not as a top-level `workflow.onComplete { }` statement --
    // Nextflow 26.x rejects that too, the same as any other bare top-level statement.
    workflow.onComplete {
        def logPattern = ~/\.nextflow\.log\.\d+/
        new File('.').listFiles().findAll { it.name ==~ logPattern }.each { it.delete() }
    }

    // Make Python scripts in bin/ executable (moved here, not top-level script scope --
    // Nextflow 26.x rejects bare statements outside a process/workflow/function, same
    // reason as the refDir/samples_ch logic below).
    "chmod +x ${projectDir}/bin/merge_salmon_counts.py".execute().waitFor()
    "chmod +x ${projectDir}/bin/merge_featurecounts.py".execute().waitFor()
    "chmod +x ${projectDir}/bin/filter_low_expression_samples.py".execute().waitFor()
    "chmod +x ${projectDir}/bin/normalize_log_tpm.py".execute().waitFor()
    "chmod +x ${projectDir}/bin/data_validation.py".execute().waitFor()
    "chmod +x ${projectDir}/bin/parse_qc.py".execute().waitFor()

    if ( ! params.outdir )    error "Please provide --outdir"

    // Auto-detect reference genome and GFF in seqFiles/ref_genome under outdir.
    // Uses Nextflow's file()/Path API (not java.io.File) so this also works when
    // params.outdir is an s3:// URI, not just a local path.
    //
    // Resolved into plain local variables, not params.ref_genome/params.ref_gff --
    // reassigning a params.* value after its initial declaration triggers Nextflow's
    // "defined multiple times" warning and the reassignment is silently discarded, so a
    // params-based version of this always left params.ref_genome/ref_gff null downstream
    // (surfacing as "Argument of file() function cannot be null" at the EXTRACT_CDS call).
    def refDir = file("${params.outdir}/seqFiles/ref_genome")
    if ( ! refDir.exists() ) error "Reference genome directory not found: ${refDir}"
    def refDirFiles = refDir.listFiles()
    def fastaFiles = refDirFiles.findAll { it.name.endsWith('.fna') || it.name.endsWith('.fa') }
    if ( fastaFiles.size() == 0 ) error "No FASTA (.fna/.fa) file found in ${refDir}"
    if ( fastaFiles.size() > 1 ) error "Multiple FASTA files found in ${refDir}: ${fastaFiles*.name}"
    def refGenome = fastaFiles[0]
    def gffFiles = refDirFiles.findAll { it.name.endsWith('.gff') }
    if ( gffFiles.size() == 0 ) error "No GFF (.gff) file found in ${refDir}"
    if ( gffFiles.size() > 1 ) error "Multiple GFF files found in ${refDir}: ${gffFiles*.name}"
    def refGff = gffFiles[0]

    if ( params.quantifier != 'bowtie2' && params.quantifier != 'salmon' )
        error "Unknown --quantifier '${params.quantifier}': expected 'bowtie2' or 'salmon'"

    // load samples from the original download samplesheet
    //
    // Existence checked eagerly here, not via a reactive `.ifEmpty{ error ... }` on the
    // Channel.fromPath below (as an earlier version of this did) -- with the rest of this
    // workflow's later operators present (FILTER_SAMPLESHEET, DATA_VALIDATION, etc. all
    // re-referencing this same path further down), that reactive ifEmpty intermittently
    // fired as if the channel were empty even when the file demonstrably existed and
    // Channel.fromPath had already emitted it, confirmed by isolated reproduction: the
    // exact same channel construction succeeds every time in a minimal script, only
    // failing once the rest of this workflow's later operators are also present. An eager
    // check matches the pattern already used above for refDir/fastaFiles/gffFiles, which
    // never showed this problem.
    def samplesheetDownloadFile = file("${params.outdir}/samplesheet/samplesheet_download.csv")
    if ( ! samplesheetDownloadFile.exists() ) error "Sample sheet not found at: ${samplesheetDownloadFile}"

    samples_ch = Channel
        .fromPath( samplesheetDownloadFile )
        .splitCsv(header: true, sep: ',')
        // remove surrounding quotes and normalize keys
        .map { row ->
            row.collectEntries { k, v ->
                def key   = k.trim().toLowerCase().replaceAll(/^"|"$/, '')
                def value = v?.toString()?.trim()?.replaceAll(/^"|"$/, '')
                [ key, value ]
            }
        }
        // keep only rows that have all required fields. No `.ifEmpty{ error ... }` guard
        // here (an earlier version had one) -- same class of issue as the eager
        // samplesheetDownloadFile check above: with this workflow's later operators
        // present, a reactive ifEmpty here intermittently fired even when the CSV
        // demonstrably had valid rows. Downstream stages already tolerate a genuinely
        // empty result on their own (FILTER_SAMPLESHEET's `[ ! -s ... ]` check,
        // MERGE_COUNTS/MERGE_COUNTS_FEATURECOUNTS's "No data to process" branch), so
        // nothing downstream actually depends on failing fast here.
        .filter { row ->
            row.id && row.fastq_1 && row.run_accession
        }
        // build the tuple for each sample using the id column which has SRX_SRR, DRX_DRR, or ERX_ERR format
        .map { row ->
            def reads = [file("${params.outdir}/${row.fastq_1}")]
            if (row.fastq_2 && row.fastq_2.trim()) {
                reads.add(file("${params.outdir}/${row.fastq_2}"))
            }
            tuple(row.id, reads)
        }

    // build index for whichever quantifier was selected
    if ( params.quantifier == 'salmon' ) {
        cds_fa_ch       = EXTRACT_CDS( refGenome, refGff )
        salmon_index_ch = SALMON_INDEX(cds_fa_ch)
    } else {
        bowtie2_index_ch = BOWTIE2_BUILD( refGenome )
    }

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

    // Quantify only QC-passed samples, then merge count matrices -- wait for
    // both quantification and samplesheet filtering
    if ( params.quantifier == 'salmon' ) {
        quant_ch = SALMON_QUANT(filtered_trimmed_ch, salmon_index_ch)
        quant_success_ch = quant_ch.filter { quant_dir -> quant_dir != null }
        count_matrix_ch = MERGE_COUNTS(
            quant_success_ch.collect(),
            passed_ch
        )
    } else {
        sam_ch = BOWTIE2_ALIGN(filtered_trimmed_ch, bowtie2_index_ch)
        sam_sort_index_out = SAM_SORT_INDEX(sam_ch)
        bam_ch = sam_sort_index_out.bam
        fc_ch  = FEATURECOUNTS(bam_ch, refGff)
        fc_success_ch = fc_ch.filter { counts_file -> counts_file != null }
        count_matrix_ch = MERGE_COUNTS_FEATURECOUNTS(
            fc_success_ch.collect(),
            passed_ch
        )
    }

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