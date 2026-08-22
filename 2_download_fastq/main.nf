/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT LOCAL MODULES/SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { SRA_FASTQ_FTP           } from './modules/sra_fastq_ftp'
include { SRA_FASTQ_AWSODP        } from './modules/sra_fastq_awsodp'
include { SRA_IDS_TO_RUNINFO      } from './modules/sra_ids_to_runinfo'
include { SRA_RUNINFO_TO_FTP      } from './modules/sra_runinfo_to_ftp'
include { SRA_TO_SAMPLESHEET      } from './modules/sra_to_samplesheet'

// Add process to clean rotated Nextflow logs
process CLEAN_NEXTFLOW_LOG {
    cache false
    tag "clean_nextflow_log"

    script:
        """
        rm -f .nextflow.log.[0-9]* || true
        """
}

workflow {

    main:
    // Registered here, not as a top-level `workflow.onComplete { }` statement --
    // Nextflow 26.x rejects that too, the same as any other bare top-level statement.
    workflow.onComplete {
        def logPattern = ~/\.nextflow\.log\.\d+/
        new File('.').listFiles().findAll { it.name ==~ logPattern }.each { it.delete() }
    }

    // Make Python scripts in bin folder executable (moved here, not top-level script
    // scope -- Nextflow 26.x rejects bare statements outside a process/workflow/function)
    "chmod +x ${projectDir}/bin/sra_ids_to_runinfo.py".execute().waitFor()
    "chmod +x ${projectDir}/bin/sra_runinfo_to_ftp.py".execute().waitFor()

    // Input channel for sample IDs from metadata CSV in workdir (same reason, moved here)
    ids = Channel
        .fromPath("${params.outdir}/metadata/sample_id.csv")
        .splitCsv(header:true)
        .map { row -> row.values().first() }

    ch_versions = Channel.empty()

    // Log concurrent download limit
    log.info "Download concurrency limit set to: ${params.max_concurrent_downloads ?: 20}"

    //
    // MODULE: Get SRA run information for public database ids
    //
    SRA_IDS_TO_RUNINFO (
        ids,
        params.ena_metadata_fields ?: ''
    )
    ch_versions = ch_versions.mix(SRA_IDS_TO_RUNINFO.out.versions.first())

    //
    // MODULE: Parse SRA run information, create file containing FTP links and read into workflow as [ meta, [reads] ]
    //
    SRA_RUNINFO_TO_FTP (
        SRA_IDS_TO_RUNINFO.out.tsv.filter { it != null && it.exists() }
    )
    ch_versions = ch_versions.mix(SRA_RUNINFO_TO_FTP.out.versions.first())

    SRA_RUNINFO_TO_FTP
        .out
        .tsv
        .filter { it != null && it.exists() }
        .splitCsv(header:true, sep:'\t')
        .map {
            meta ->
                def meta_clone = meta.clone()
                meta_clone.single_end = meta_clone.single_end.toBoolean()
                return meta_clone
        }
        .unique()
        .set { ch_sra_metadata }

    if (!params.skip_fastq_download) {

        // Skip AWSODP/FTP entirely for samples already sitting in the publishDir from a
        // prior run/resume. Nextflow only caches *successful* task executions -- a sample
        // that failed on AWSODP but was recovered via the FTP fallback below has no cache
        // entry for the AWSODP attempt itself (it never succeeded), so a fresh or resumed
        // session re-attempts AWSODP from scratch for it every time, even though the
        // actual FASTQ data is already downloaded and sitting right here. Both download
        // modules publish to the same "${params.outdir}/seqFiles/fastq" location with the
        // same ${meta.id}[_1/_2].fastq.gz naming regardless of which one produced it, so a
        // simple existence check here recognizes success via *either* path, not just
        // whichever one Nextflow's own cache happens to remember.
        ch_sra_metadata
            .map { meta ->
                def base = "${params.outdir}/seqFiles/fastq"
                def already_downloaded = meta.single_end
                    ? file("${base}/${meta.id}.fastq.gz").exists()
                    : (file("${base}/${meta.id}_1.fastq.gz").exists() && file("${base}/${meta.id}_2.fastq.gz").exists())
                [ meta, already_downloaded ]
            }
            .branch {
                meta, already_downloaded ->
                    skip: already_downloaded
                        return meta.id
                    download: !already_downloaded
                        return meta
            }
            .set { ch_sra_download_check }

        ch_sra_download_check.skip
            .collect()
            .subscribe { skippedIds -> if (skippedIds) log.info "Skipping download for ${skippedIds.size()} sample(s) already present in ${params.outdir}/seqFiles/fastq: ${skippedIds.join(', ')}" }

        ch_sra_download_check.download
            .set { ch_sra_metadata_to_download }

        ch_sra_metadata_to_download
            .branch {
                meta ->
                    def download_method = 'ftp'
                    // meta.fastq_aspera is a metadata string with ENA fasp links supported by Aspera
                        // For single-end: 'fasp.sra.ebi.ac.uk:/vol1/fastq/ERR116/006/ERR1160846/ERR1160846.fastq.gz'
                        // For paired-end: 'fasp.sra.ebi.ac.uk:/vol1/fastq/SRR130/020/SRR13055520/SRR13055520_1.fastq.gz;fasp.sra.ebi.ac.uk:/vol1/fastq/SRR130/020/SRR13055520/SRR13055520_2.fastq.gz'
                    if (meta.fastq_aspera && params.download_method == 'aspera') {
                        download_method = 'aspera'
                    }
                    if ((!meta.fastq_aspera && !meta.fastq_1) || params.download_method == 'sratools') {
                        download_method = 'sratools'
                    }

                    aspera: download_method == 'aspera'
                        return [ meta, meta.fastq_aspera.tokenize(';').take(meta.single_end ? 1 : 2) ]
                    ftp: download_method == 'ftp'
                        return [ meta, meta.single_end ? [ meta.fastq_1 ] : [ meta.fastq_1, meta.fastq_2 ] ]
                    sratools: download_method == 'sratools'
                        return [ meta, meta.run_accession ]
            }
            .set { ch_sra_reads }

        //
        // MODULE: Otherwise (the default), fetch the run directly from NCBI SRA's AWS Open
        // Data buckets (s3://sra-pub-run-odp) and convert to FastQ with fasterq-dump. This
        // is the default download_method ('sratools'); set --download_method ftp to use
        // SRA_FASTQ_FTP for every sample instead.
        //
        SRA_FASTQ_AWSODP (
            ch_sra_reads.sratools
        )
        ch_versions = ch_versions.mix(SRA_FASTQ_AWSODP.out.versions.first())

        // Any 'sratools' sample AWSODP produced no output for (5 retries exhausted, optional
        // output empty) that also has an ENA FTP link in its metadata: retry once via
        // SRA_FASTQ_FTP instead of silently dropping it. Standard Nextflow anti-join: pair
        // the original per-sample input against AWSODP's output by meta.id; remainder:true
        // surfaces samples with no match (fastq == null) on the AWSODP side.
        ch_sra_reads.sratools
            .map { meta, run_accession -> [ meta.id, meta ] }
            .join(
                SRA_FASTQ_AWSODP.out.fastq.map { meta, fastq -> [ meta.id, fastq ] },
                remainder: true
            )
            .filter { id, meta, fastq -> fastq == null }
            .map { id, meta, fastq -> meta }
            .set { ch_awsodp_failed }

        ch_awsodp_failed
            .filter { meta -> !meta.fastq_1 }
            .map { meta -> meta.id }
            .collect()
            .subscribe { failedIds -> if (failedIds) log.warn "No ENA FTP link available -- ${failedIds.size()} run(s) could not be downloaded from either source: ${failedIds.join(', ')}" }

        ch_awsodp_failed
            .filter { meta -> meta.fastq_1 }
            .map { meta -> [ meta, meta.single_end ? [ meta.fastq_1 ] : [ meta.fastq_1, meta.fastq_2 ] ] }
            .set { ch_sratools_fallback_ftp }

        //
        // MODULE: If FTP link is provided in run information then download FastQ directly via
        // FTP and validate with md5sums. Also receives sratools/AWSODP failures with an ENA
        // link (ch_sratools_fallback_ftp above) as an automatic fallback.
        //
        SRA_FASTQ_FTP (
            ch_sra_reads.ftp.mix(ch_sratools_fallback_ftp)
        )
        ch_versions = ch_versions.mix(SRA_FASTQ_FTP.out.versions.first())

    //
    // MODULE: Stage FastQ files downloaded by SRA together and auto-create a samplesheet
    //
    SRA_TO_SAMPLESHEET (
        ch_sra_metadata,
        params.nf_core_pipeline ?: '',
        params.nf_core_rnaseq_strandedness ?: 'auto',
        params.sample_mapping_fields
    )

    // Merge samplesheets and mapping files across all samples
    SRA_TO_SAMPLESHEET
        .out
        .samplesheet
        .filter { it != null && it[1] != null && it[1].exists() }
        .map { it[1] }
        .collectFile(name:'tmp_samplesheet.csv', newLine: true, keepHeader: true, sort: { it.baseName })
        .map { it.text.tokenize('\n').join('\n') }
        .collectFile(name:'samplesheet_download.csv', storeDir: "${params.outdir}/samplesheet")
        .set { ch_samplesheet }
    }
}