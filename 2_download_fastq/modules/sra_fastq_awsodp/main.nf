process SRA_FASTQ_AWSODP {
    maxForks params.max_concurrent_downloads ?: 20
    maxRetries 5
    errorStrategy { task.attempt < 5 ? 'retry' : 'ignore' }
    tag "$meta.id"
    label 'process_low'
    label 'error_retry'
    publishDir "${params.outdir}/seqFiles/fastq", mode: params.publish_dir_mode

    container "${params.sra_awsodp_container ?: 'public.ecr.aws/YOUR_ECR_ALIAS/mapped/sra-fastq-awsodp:1.0'}"

    input:
    tuple val(meta), val(run_accession)

    output:
    tuple val(meta), path("*fastq.gz"), emit: fastq, optional: true
    path "versions.yml",                emit: versions

    script:
    """
    set -euo pipefail

    # Fetch the run directly from NCBI SRA's AWS Open Data bucket (public, no-sign-request,
    # us-east-1) instead of NCBI's public internet endpoints. See AWS_SETUP.md.
    aws s3 cp --no-sign-request \\
        s3://sra-pub-run-odp/sra/${run_accession}/${run_accession} \\
        ./${run_accession}.sra

    fasterq-dump ./${run_accession}.sra --split-files --threads ${task.cpus} --outdir .

    if [ -f ${run_accession}_1.fastq ] && [ -f ${run_accession}_2.fastq ]; then
        mv ${run_accession}_1.fastq ${meta.id}_1.fastq
        mv ${run_accession}_2.fastq ${meta.id}_2.fastq
        gzip ${meta.id}_1.fastq ${meta.id}_2.fastq
    elif [ -f ${run_accession}.fastq ]; then
        mv ${run_accession}.fastq ${meta.id}.fastq
        gzip ${meta.id}.fastq
    else
        echo "ERROR: fasterq-dump produced no fastq output for ${run_accession}" >&2
        exit 1
    fi

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        sra-tools: \$(fasterq-dump --version 2>&1 | sed -n 's/.*fasterq-dump : //p')
        awscli: \$(aws --version 2>&1 | sed 's/ Python.*//')
    END_VERSIONS
    """
}
