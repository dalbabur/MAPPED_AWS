# MAPPED - Modular Automated Pipeline for Public Expression Data

MAPPED (Modular Automated Pipeline for Public Expression Data) is a comprehensive Nextflow-based workflow designed to analyze public RNA-seq data from NCBI SRA. It automates the entire process from metadata retrieval to expression matrix generation, making large-scale transcriptomics analysis accessible and reproducible.

## Overview

MAPPED consists of four integrated modules that work together to process public expression data:

1. **Metadata Download**: Retrieves and formats metadata from NCBI SRA based on organism name
2. **FASTQ Download**: Efficiently downloads sequencing data using optimized protocols
3. **Reference Genome Download**: Obtains reference genome sequences and annotations
4. **Expression Quantification**: Performs quality control, trimming, and gene expression quantification

The pipeline is designed to handle large-scale datasets with built-in error handling, resume capabilities, and resource optimization.

## Features

- **Automated end-to-end workflow**: From organism name to expression matrices in a single command
- **Flexible reference genome selection**: Use default reference strains or specify custom genome accessions
- **Robust error handling**: Automatic retries and graceful failure management
- **Resume capability**: Continue from any interruption point without re-processing
- **Resource optimization**: Configurable CPU allocation and efficient storage management
- **Clean mode**: Automatic cleanup of intermediate files to save disk space
- **Docker integration**: No manual dependency installation required
- **Comprehensive quality control**: FastQC and MultiQC reports included
- **Strain filtering**: Optionally restrict samples by strain token in ScientificName
- **AWS-ready**: Run on AWS Batch against S3, with FASTQ sourced directly from NCBI SRA's
  AWS Open Data buckets instead of ENA's FTP mirror — see [Running on AWS](#running-on-aws).
  Every AWS-mode run also self-registers into a queryable Glue/Athena catalog of runs and
  samples, so results from different runs can be discovered and cross-referenced later

## Prerequisites

- **[Nextflow](https://www.nextflow.io/)** (version 21.04.0 or later)
- **[Docker](https://www.docker.com/)** (version 20.10 or later)

Additionally, to run on AWS: an AWS account and the environment described in
[AWS_SETUP.md](AWS_SETUP.md) (AWS Batch compute environment, S3 buckets, IAM roles).

## Installation

1. Clone the MAPPED repository:
```bash
git clone https://github.com/your-org/MAPPED.git
cd MAPPED
```

2. Ensure the wrapper script is executable:
```bash
chmod +x run_MAPPED.sh
```

3. Verify Nextflow and Docker are installed:
```bash
nextflow -version
docker --version
```

## Quick Start

Process RNA-seq data for an organism using the default reference genome:

```bash
./run_MAPPED.sh \
    --organism "Escherichia coli" \
    --outdir ./results \
    --workdir ./work \
    --library_layout paired \
    --cpu 48
```

## Usage

### Basic Usage

The `run_MAPPED.sh` wrapper script orchestrates all pipeline modules:

```bash
./run_MAPPED.sh [OPTIONS]
```

### Using a Specific Reference Genome

To use a specific genome assembly instead of the default reference strain:

```bash
./run_MAPPED.sh \
    --organism "Streptomyces coelicolor" \
    --ref-accession GCA_008931305.1 \
    --outdir ./results \
    --workdir ./work \
    --library_layout paired \
    --cpu 24
```

### Clean Mode

To automatically clean up intermediate files after successful completion:

```bash
./run_MAPPED.sh \
    --organism "Pseudomonas putida" \
    --outdir ./results \
    --workdir ./work \
    --library_layout paired \
    --cpu 16 \
    --clean-mode
```

## Running on AWS

Pass `s3://` URIs for `--outdir`/`--workdir` and the pipeline runs on AWS Batch instead
of your local machine, pulling FASTQ directly from NCBI SRA's AWS Open Data buckets
(`s3://sra-pub-run-odp`) instead of ENA's FTP mirror:

```bash
./run_MAPPED.sh \
    --organism "Escherichia coli" \
    --outdir s3://my-mapped-bucket/results \
    --workdir s3://my-mapped-bucket/work \
    --library_layout paired \
    --cpu 16
```

This requires the AWS environment (IAM roles, VPC, S3 buckets, AWS Batch compute
environment/queue) described in **[AWS_SETUP.md](AWS_SETUP.md)** to already exist.
`--clean-mode` is local-only (use an S3 Lifecycle rule instead — see AWS_SETUP.md).

### Run/sample discovery catalog

Every run against `s3://` `--outdir`/`--workdir` also registers itself, right after
Stage 4 finishes, into a small AWS Glue Data Catalog spanning the whole bucket —
`s3://<bucket>/catalog/runs/` and `s3://<bucket>/catalog/samples/`, queryable via Athena
as `mapped_catalog.mapped_runs` / `mapped_catalog.mapped_samples`. This is how you find
what's already been processed (by organism, strain, BioProject, or SRA/ENA accession)
across every run anyone has pointed at the bucket, without needing to know each run's
`--outdir` ahead of time. It's a discovery index only — it does not merge or deduplicate
`expression_matrices/` across runs. Setup (one-time, admin-provisioned) and example
queries are in [AWS_SETUP.md](AWS_SETUP.md), §14.

### Skipping already-processed samples

Pass `--skip-processed` to avoid redownloading and requantifying a sample your bucket has
already fully processed. Before Step 2 (FASTQ download), it queries the catalog above for
accessions already processed for this `--organism` **against the same reference genome**
— not organism alone, since the same accession quantified against a different reference
is a different result, not a repeat of the same computation — and removes them from this
run's sample list. To know the reference genome ahead of the usual point in the pipeline,
`--skip-processed` runs Step 3 (reference genome download) before Step 2 instead of after
it; this only happens when the flag is set, so it changes nothing for runs that don't use
it. If every requested sample turns out to already be processed, the run stops right there
(nothing to download) and tells you where the existing results live — it does not merge
them into this run for you; that's still a manual step using the `outdir` it reports.

```bash
./run_MAPPED.sh \
    --organism "Pseudomonas putida" \
    --outdir s3://my-mapped-bucket/results/putida-batch2 \
    --workdir s3://my-mapped-bucket/work/putida-batch2 \
    --library_layout single \
    --skip-processed \
    --cpu 16
```

## Pipeline Modules

### 1. Download Metadata (Module 1)
- Queries NCBI SRA for RNA-seq experiments matching the specified organism
- Filters samples based on library layout (single-end, paired-end, or both)
- Generates formatted metadata files for downstream processing

### 2. Download FASTQ (Module 2)
- Downloads raw sequencing data — by default directly from NCBI SRA's AWS Open Data
  buckets (`s3://sra-pub-run-odp`) via `sra-tools`; falls back to ENA's FTP mirror if
  `--download_method ftp` is set
- Validates downloaded files
- Creates a samplesheet for downstream analysis

### 3. Download Reference Genome (Module 3)
- Downloads reference genome assemblies from NCBI
- Retrieves genome sequence (FASTA), annotations (GFF), and protein sequences (FAA)
- Supports two modes:
  - **Default mode**: Automatically selects the largest reference genome for the organism
  - **Accession mode**: Downloads a specific genome assembly using its accession number

### 4. Generate Count Matrix (Module 4)
- Performs quality control on raw reads (FastQC)
- Trims adapters and low-quality bases (TrimGalore)
- Quantifies gene expression against every gene type in the GFF (protein-coding, tRNA,
  rRNA, ncRNA) using Bowtie2 + featureCounts (default), or optionally the original
  CDS-only Salmon path via `--quantifier salmon` (see `4_generate_count_matrix/README.md`)
- Generates normalized expression matrices (TPM and raw counts)
- Creates comprehensive quality reports (MultiQC)

## Parameters

### Required Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `--organism` | Full taxonomic name of the target organism | `"Escherichia coli"` |
| `--outdir` | Output directory for all results | `/path/to/results` |
| `--workdir` | Nextflow work directory for temporary files | `/path/to/work` |
| `--library_layout` | Sequencing library type: `single`, `paired`, or `both` | `paired` |

### Optional Parameters

| Parameter | Description | Default | Example |
|-----------|-------------|---------|---------|
| `--cpu` | Number of CPUs to allocate per process | System dependent | `16` |
| `--ref-accession` | Specific reference genome accession | Auto-selected | `GCA_008931305.1` |
| `--max_concurrent_downloads` | Maximum number of concurrent FASTQ downloads | `20` | `10` |
| `--strain` | Filter by strain token in `ScientificName` (case-insensitive token equals/contains) | none | `K-12` |
| `--clean-mode` | Remove intermediate files after completion | `false` | (flag) |
| `--force` | Proceed even if `--outdir` already holds results from a different configuration (see [Output directory reuse](#output-directory-reuse)) | `false` | (flag) |
| `--skip-processed` | s3:// mode only. Skip samples already processed for this organism against the same reference genome (see [Skipping already-processed samples](#skipping-already-processed-samples)) | `false` | (flag) |
| `-h, --help` | Display help message | - | (flag) |

## Output Structure

The pipeline creates a well-organized output directory structure:

```
${outdir}/
├── .mapped_run_manifest         # Records this run's configuration (see below); not a pipeline result
├── metadata/                    # Downloaded and formatted metadata
│   ├── <Organism>_metadata.tsv  # Cleaned metadata (optionally strain-filtered)
│   └── sample_id.csv            # List of SRA accessions (optionally strain-filtered)
├── samplesheet/                 # Sample information for processing
│   ├── samplesheet_download.csv # metadata for all the available samples from NCBI
│   └── samplesheet.csv          # metadata for the samples that passed QC and quantified in the workflow
├── seqFiles/                    # Reference genome files
│   └── ref_genome/
│       ├── *.fna                # Genome sequence (FASTA)
│       ├── *.gff                # Gene annotations (GFF3)
│       ├── *.faa                # Protein sequences (FASTA)
│       └── datasets_summary.json
├── fastqc/                      # Quality control reports
│   ├── *_fastqc.html            # Per-sample QC reports
│   └── *_fastqc.zip             # QC data files
├── trimmed/                     # Adapter-trimmed FASTQ files
│   ├── *_trimmed.fq.gz          # Trimmed sequences
│   └── *_trimming_report.txt
├── bowtie2/                      # Sorted, indexed BAMs (--quantifier bowtie2, default)
├── featurecounts/                # Per-sample gene counts (--quantifier bowtie2, default)
├── salmon/                       # Expression quantification (--quantifier salmon)
│   └── <sample_id>/
│       └── quant.sf             # Quantification results
├── expression_matrices/         # Final expression data
│   ├── counts.csv               # Raw count matrix
│   ├── tpm.csv                  # TPM normalized matrix
│   ├── log_tpm.csv              # Log-transformed TPM
│   └── log_tpm_norm.csv         # Log-transformed normalized TPM
└── multiqc/                     # Aggregated quality reports
    ├── multiqc_report.html      # Interactive report
    └── multiqc_data/            # Raw MultiQC data
```

### Output directory reuse

`run_MAPPED.sh` refuses to run if `--outdir` already holds results from a *different*
configuration than the one you just passed — several `publishDir` directives overwrite
in place, so reusing an `--outdir` by mistake would silently destroy prior results.

On every run, it compares `--organism`/`--strain`/`--bioproject`/`--sra_accessions`/
`--library_layout`/`--ref-accession` (the parameters that determine *what data* ends up
in `--outdir` — not `--workdir`/`--cpu`, which are safe to change) against
`.mapped_run_manifest`, a small file it writes at the root of `--outdir` the first time
it's used:

- **First use of an `--outdir`**: no manifest yet, proceeds normally and writes one.
- **Same `--outdir`, same configuration** (e.g. resuming after an interruption): manifest
  matches, proceeds normally — this is the normal resume workflow and needs no extra flag.
- **Same `--outdir`, different configuration**: refuses to run, and shows exactly which
  parameters differ from what's recorded. Pick a different `--outdir`, or pass `--force`
  to proceed anyway and overwrite (this also re-registers the manifest with the new
  configuration, so later runs against this same `--outdir` are compared against it
  instead).

This is a best-effort guard, not a distributed lock — two invocations starting at the
exact same instant against the same fresh `--outdir` can still race. In practice this
only matters if you're scripting concurrent launches; for normal interactive use it isn't
a concern.

### Clean Mode Output

When using `--clean-mode`, only essential outputs are retained:
```
${outdir}/
├── expression_matrices/     # Final expression matrices
├── samplesheet/            # Sample metadata
└── ref_genome/             # Reference genome files
### Strain Filtering

Restrict analysis to samples whose `ScientificName` contains a specific strain token. The value is matched case-insensitively against space-delimited tokens of `ScientificName`; a row is kept if any token equals or contains the provided string.

Example:

```bash
./run_MAPPED.sh \
    --organism "Escherichia coli" \
    --strain "K-12" \
    --outdir ./results \
    --workdir ./work \
    --library_layout paired \
    --cpu 24
```

This filters metadata to samples whose `ScientificName` tokens match `K-12` (e.g., token equals `K-12` or contains `K-12`). The filtered set propagates to `metadata/sample_id.csv` and all downstream steps.

```
