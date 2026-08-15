process SRA_TO_SAMPLESHEET {
    tag "$meta.id"
    errorStrategy 'ignore'

    // No local-filesystem work needed here (just two `echo`s), but AWS Batch requires
    // every job to run in a container regardless -- reusing the image already pulled by
    // sibling processes in this module avoids an extra image on the compute environment.
    container 'quay.io/biocontainers/biopython:1.79'
    memory 100.MB

    input:
    val meta
    val pipeline
    val strandedness
    val mapping_fields

    output:
    tuple val(meta), path("*samplesheet.csv"), emit: samplesheet, optional: true

    script:
    // Build only the samplesheet with local fastq paths
    def mclone = meta.clone()
    ['fastq_1','fastq_2','md5_1','md5_2','single_end'].each { mclone.remove(it) }
    def sampleId = meta.id.split('_')[0..-2].join('_')
    // Relative to params.outdir, matching SRA_FASTQ_FTP/SRA_FASTQ_AWSODP's shared
    // publishDir ("${params.outdir}/seqFiles/fastq"). Previously built from
    // params.workdir, a param that was never actually set (the real work-dir is passed
    // via Nextflow's native -work-dir flag) -- this produced a leading-slash path that
    // happened to self-correct via "//" collapsing on a local POSIX filesystem, but not
    // on S3, where "//" is not collapsed.
    def baseMap = [ sample: sampleId ]
    if (meta.single_end.toString().toBoolean()) {
        baseMap.fastq_1 = "seqFiles/fastq/${meta.id}.fastq.gz"
        baseMap.fastq_2 = ""
    } else {
        baseMap.fastq_1 = "seqFiles/fastq/${meta.id}_1.fastq.gz"
        baseMap.fastq_2 = "seqFiles/fastq/${meta.id}_2.fastq.gz"
    }
    def pipeline_map = baseMap + mclone
    def header = pipeline_map.keySet().collect{ "\"${it}\"" }.join(',')
    def values = pipeline_map.values().collect{ "\"${it}\"" }.join(',')
    return """#!/usr/bin/env bash
echo '${header}' > ${meta.id}.samplesheet.csv
echo '${values}' >> ${meta.id}.samplesheet.csv
"""
}
