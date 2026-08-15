process SRA_RUNINFO_TO_FTP {

    container 'quay.io/biocontainers/biopython:1.79'
    errorStrategy 'ignore'

    input:
    path runinfo

    output:
    path "*.tsv"       , emit: tsv, optional: true
    path "versions.yml", emit: versions

    script:
    """
    sra_runinfo_to_ftp.py \\
        ${runinfo.join(',')} \\
        ${runinfo.toString().tokenize(".")[0]}.runinfo_ftp.tsv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python --version | sed 's/Python //g')
    END_VERSIONS
    """
}
