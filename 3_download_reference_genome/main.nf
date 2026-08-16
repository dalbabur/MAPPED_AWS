#!/usr/bin/env nextflow

// Workflow to download a reference genome from NCBI and save to outdir

workflow {
    // Registered here, not as a top-level `workflow.onComplete { }` statement --
    // Nextflow 26.x rejects that too, the same as any other bare top-level statement.
    workflow.onComplete {
        def logPattern = ~/\.nextflow\.log\.\d+/
        new File('.').listFiles().findAll { it.name ==~ logPattern }.each { it.delete() }
    }

    if (params.ref_accession) {
        // If ref_accession is provided, use it directly
        DOWNLOAD_REFERENCE_BY_ACCESSION(params.ref_accession)
    } else if (params.organism) {
        // Otherwise, use organism name to find reference genome
        DOWNLOAD_REFERENCE(params.organism)
    } else {
        error "Missing required parameter: either --organism or --ref_accession must be provided"
    }
}

process DOWNLOAD_REFERENCE {
    publishDir "${params.outdir}/seqFiles", mode: 'copy', overwrite: true

    input:
    val organism

    output:
    path 'ref_genome/*.fna'
    path 'ref_genome/*.gff'
    path 'ref_genome/*.faa'
    path 'ref_genome/datasets_summary.json'

    script:
    """
    # Get the summary as JSON Lines and extract the RefSeq accession (GCF_...) and
    # genome size via NCBI's own `dataformat` tool rather than hand-parsing JSON with
    # grep/awk -- the pretty-printed report has multiple unrelated "*accession*" fields
    # per record (biosample accession, bioproject accession, paired_accession, etc.), and
    # naive pattern matching previously locked onto "paired_accession" (the record's
    # linked GenBank/GCA counterpart) instead of the record's own top-level "accession"
    # (its RefSeq/GCF accession, guaranteed present since --assembly-source refseq is
    # set below). The paired GCA assembly frequently lacks the GCF's PGAP-generated
    # GFF3/protein annotation files, which this process's output: block requires --
    # silently failing every task with "missing output file(s)" despite the download
    # script itself exiting 0, since the GCA package only ever contained the genome FASTA.
    datasets summary genome taxon '${organism}' --reference --assembly-source refseq --as-json-lines > summary.jsonl

    # Check if we got any results
    if [ ! -s summary.jsonl ]; then
        echo "ERROR: No reference genomes found for ${organism}"
        exit 1
    fi

    total_count=\$(wc -l < summary.jsonl)
    echo "Found \$total_count reference genome(s)"

    dataformat tsv genome --inputfile summary.jsonl \
        --fields accession,assmstats-total-sequence-len --elide-header > gca_list.txt

    # Check if we found any accessions
    if [ ! -s gca_list.txt ]; then
        echo "ERROR: No RefSeq accessions found in the reference genomes"
        exit 1
    fi

    # Sort by size (second column) and get the largest
    selected_gca=\$(sort -k2 -nr gca_list.txt | head -n1 | awk '{print \$1}')

    if [ -z "\$selected_gca" ]; then
        echo "ERROR: Failed to select a RefSeq accession"
        exit 1
    fi

    echo "Selected RefSeq accession: \$selected_gca (largest genome)"

    # Download the specific RefSeq accession
    datasets download genome accession "\$selected_gca" --include gff3,protein,genome --filename ref.zip

    # Extract and organize files
    unzip ref.zip -d tmp

    # Find the downloaded assembly directory -- named exactly after the accession
    # requested, so match it directly rather than assuming a GCA_/GCF_ prefix.
    gca_dir=\$(find tmp/ncbi_dataset/data -mindepth 1 -maxdepth 1 -type d -name "\$selected_gca" | head -n1)

    if [ -z "\$gca_dir" ]; then
        echo "Error: Assembly directory not found after download"
        exit 1
    fi

    mkdir -p ref_genome
    
    # Copy fna files
    for fna in "\$gca_dir"/*_genomic.fna "\$gca_dir"/*.fna; do
        if [ -f "\$fna" ]; then
            cp "\$fna" "ref_genome/\$(basename "\$fna")"
            break
        fi
    done
    
    # Copy gff files
    for gff in "\$gca_dir"/*genomic.gff "\$gca_dir"/*.gff; do
        if [ -f "\$gff" ]; then
            cp "\$gff" "ref_genome/\$(basename "\$gff")"
            break
        fi
    done
    
    # Copy protein files
    for faa in "\$gca_dir"/*protein.faa "\$gca_dir"/*.faa; do
        if [ -f "\$faa" ]; then
            cp "\$faa" "ref_genome/\$(basename "\$faa")"
            break
        fi
    done
    
    # Save the datasets summary
    cp summary.jsonl ref_genome/datasets_summary.json

    # Ensure output files are world-readable for publishDir
    chmod a+r ref_genome/*

    # Cleanup
    rm -rf tmp ref.zip summary.jsonl gca_list.txt
    """
}

process DOWNLOAD_REFERENCE_BY_ACCESSION {
    publishDir "${params.outdir}/seqFiles", mode: 'copy', overwrite: true

    input:
    val accession

    output:
    path 'ref_genome/*.fna'
    path 'ref_genome/*.gff'
    path 'ref_genome/*.faa'
    path 'ref_genome/datasets_summary.json'

    script:
    """
    # Validate accession format -- GCA_ (GenBank) or GCF_ (RefSeq) are both valid NCBI
    # assembly accession prefixes. RefSeq/GCF is usually the better choice when both
    # exist for the same assembly: it carries NCBI's own PGAP annotation, whereas the
    # paired GenBank/GCA submission frequently lacks GFF3/protein files entirely (the
    # same gap DOWNLOAD_REFERENCE's own auto-selection logic was fixed to avoid).
    if [[ ! "${accession}" =~ ^GC[AF]_[0-9]+\\.[0-9]+\$ ]]; then
        echo "ERROR: Invalid accession format: ${accession}"
        echo "Expected format: GCA_XXXXXXXXX.Y or GCF_XXXXXXXXX.Y (e.g., GCF_000007565.2)"
        exit 1
    fi

    echo "Downloading genome for accession: ${accession}"

    # Download the specific accession
    datasets download genome accession "${accession}" --include gff3,protein,genome --filename ref.zip

    # Extract and organize files
    unzip ref.zip -d tmp

    # Find the downloaded assembly directory -- named exactly after the accession
    # requested, so match it directly rather than assuming a GCA_ prefix (which silently
    # found nothing at all for a GCF_ accession).
    gca_dir=\$(find tmp/ncbi_dataset/data -mindepth 1 -maxdepth 1 -type d -name "${accession}" | head -n1)

    if [ -z "\$gca_dir" ]; then
        echo "Error: Assembly directory not found after download"
        exit 1
    fi
    
    mkdir -p ref_genome
    
    # Copy fna files
    for fna in "\$gca_dir"/*_genomic.fna "\$gca_dir"/*.fna; do
        if [ -f "\$fna" ]; then
            cp "\$fna" "ref_genome/\$(basename "\$fna")"
            break
        fi
    done
    
    # Copy gff files
    for gff in "\$gca_dir"/*genomic.gff "\$gca_dir"/*.gff; do
        if [ -f "\$gff" ]; then
            cp "\$gff" "ref_genome/\$(basename "\$gff")"
            break
        fi
    done
    
    # Copy protein files
    for faa in "\$gca_dir"/*protein.faa "\$gca_dir"/*.faa; do
        if [ -f "\$faa" ]; then
            cp "\$faa" "ref_genome/\$(basename "\$faa")"
            break
        fi
    done
    
    # Create a summary JSON for compatibility
    echo '{"ref_accession": "${accession}"}' > ref_genome/datasets_summary.json
    
    # Ensure output files are world-readable for publishDir
    chmod a+r ref_genome/*
    
    # Cleanup
    rm -rf tmp ref.zip
    """
}