process SRA_FASTQ_AWSODP {
    // Cast to Integer: a CLI-supplied --max_concurrent_downloads arrives as a String,
    // unlike nextflow.config's own Integer default, and maxForks' internal Groovy
    // comparisons choke on comparing a String to an int ("Cannot compare
    // java.lang.String ... with java.lang.Integer") if not coerced here.
    maxForks (params.max_concurrent_downloads as Integer) ?: 20
    maxRetries 5
    errorStrategy { task.attempt < 5 ? 'retry' : 'ignore' }
    tag "$meta.id"
    label 'process_low'
    label 'error_retry'
    publishDir "${params.outdir}/seqFiles/fastq", mode: params.publish_dir_mode

    // Default points at this deployment's private ECR repo (see AWS_SETUP.md §7).
    // Override with --sra_awsodp_container if you push to a different account/repo.
    container "${params.sra_awsodp_container ?: '347076821446.dkr.ecr.us-east-1.amazonaws.com/mapped/sra-fastq-awsodp:1.0'}"

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

    # --split-files always names output(s) after whichever read-types actually contain
    # data -- for paired-end runs that's _1 and _2, but for a single-end run whose SRA
    # archive still records a second, entirely 0-length technical read (common for some
    # library preps), fasterq-dump drops that empty side silently and writes only _1,
    # never creating _2 at all. Requiring both to exist misreads a perfectly good
    # single-end result as "no output produced".
    if [ -f ${run_accession}_1.fastq ] && [ -f ${run_accession}_2.fastq ]; then
        mv ${run_accession}_1.fastq ${meta.id}_1.fastq
        mv ${run_accession}_2.fastq ${meta.id}_2.fastq
        gzip ${meta.id}_1.fastq ${meta.id}_2.fastq
    elif [ -f ${run_accession}_1.fastq ]; then
        mv ${run_accession}_1.fastq ${meta.id}.fastq
        gzip ${meta.id}.fastq
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
