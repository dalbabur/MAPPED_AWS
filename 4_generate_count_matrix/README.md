# Step 4: Generate Gene Count Matrix Pipeline

This Nextflow DSL2 pipeline processes raw FASTQ files to produce a gene-level count matrix for prokaryotic genomes.

## Prerequisites

- Nextflow
- Docker

## Usage

```bash
nextflow run main.nf --outdir ../test_results/  -resume
```

## Parameters

- `--outdir <Path>`: Directory containing:
  - `samplesheet/samplesheet.csv` with columns `sample`, `run_accession`, `fastq_1`, `fastq_2`.
  - `seqFiles/fastq/` containing the FASTQ files.
  - `seqFiles/ref_genome/` containing exactly one FASTA (`.fna`/`.fa`) and one GFF (`.gff`) file, which will be auto-detected.
- `--quantifier <bowtie2|salmon>` (default: `bowtie2`): which gene-quantification method to run.

## Quantification methods

### `bowtie2` (default)

`BOWTIE2_BUILD`/`BOWTIE2_ALIGN` align trimmed reads to the **whole genome**, then
`FEATURECOUNTS` assigns them to **every `gene` feature in the GFF** (`-t gene -g locus_tag`)
-- protein-coding, tRNA, rRNA, and ncRNA genes alike, not just CDS. Because alignment
happens against the full genome rather than a curated reference, reads landing in
non-coding RNA genes are counted (and visible as their own rows) instead of silently
falling out as "unmapped."

This is the default because a same-genome diagnostic on this pipeline's *P. putida* smoke
test showed the previous CDS-only Salmon path structurally cannot see reads from the ~100
non-coding RNA genes in this organism's annotation -- switching a CDS-only reference to a
full-transcript one made no difference to protein-coding gene quantification (this
organism's GFF has no annotated UTRs), but genome-wide alignment does surface the
non-coding fraction, which is useful for judging rRNA depletion quality per sample.

### `salmon`

The original CDS-only pseudo-alignment path: `EXTRACT_CDS` (`gffread -x`) extracts
protein-coding CDS sequences only, `SALMON_INDEX` builds a transcript-level index from
them, and `SALMON_QUANT` quasi-maps reads directly against it. Kept as an opt-in
(`--quantifier salmon`) since it mirrors the CDS-focused methodology of the PRECISE/
iModulon papers this pipeline is designed to feed. Reads from anything not in the CDS-only
reference (non-coding RNA, intergenic space) are invisible to this path by construction,
not filtered out after the fact -- there's no "unassigned" breakdown to inspect.

Both paths converge on the same `expression_matrices/{tpm,log_tpm,counts}.csv` format
(one row per gene, one column per experiment), so everything downstream (QC filtering,
log-TPM normalization, samplesheet validation) is identical either way.

## Outputs

- `fastqc/`: FastQC reports.
- `trimmed/`: Trimmed FASTQ files.
- `bowtie2/`: Coordinate-sorted, indexed BAM files (`--quantifier bowtie2`, the default).
- `featurecounts/`: Per-sample featureCounts gene count files (`--quantifier bowtie2`).
- `salmon/`: Salmon quantification results (`--quantifier salmon`).
- `multiqc/`: MultiQC report.
- `expression_matrices/`: TPM, log-TPM, and counts matrices.
