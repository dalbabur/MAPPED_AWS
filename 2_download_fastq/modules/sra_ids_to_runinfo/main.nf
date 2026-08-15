process SRA_IDS_TO_RUNINFO {
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
