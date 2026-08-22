process SRA_IDS_TO_RUNINFO {
    // Same knob as SRA_FASTQ_FTP/SRA_FASTQ_AWSODP -- without this, AWS Batch fans this
    // out to one task per sample with no local throttle, all hitting ENA's metadata API
    // simultaneously at compendium scale (hundreds of samples), unlike the download
    // modules which have always capped this deliberately.
    // Cast to Integer: a CLI-supplied --max_concurrent_downloads arrives as a String,
    // unlike nextflow.config's own Integer default, and maxForks' internal Groovy
    // comparisons choke on comparing a String to an int ("Cannot compare
    // java.lang.String ... with java.lang.Integer") if not coerced here.
    maxForks( (params.max_concurrent_downloads as Integer) ?: 20 )
    tag "$id"
    label 'error_retry'
    errorStrategy 'ignore'

    container 'quay.io/biocontainers/biopython:1.79'

    input:
    val id
    val fields

    output:
    path "*.tsv"       , emit: tsv, optional: true
    path "versions.yml", emit: versions

    script:
    def metadata_fields = fields ? "--ena_metadata_fields ${fields}" : ''
    """
    echo $id > id.txt
    sra_ids_to_runinfo.py \\
        id.txt \\
        ${id}.runinfo.tsv \\
        $metadata_fields

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python --version | sed 's/Python //g')
    END_VERSIONS
    """
}
