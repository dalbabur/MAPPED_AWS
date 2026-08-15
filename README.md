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
  AWS Open Data buckets instead of ENA's FTP mirror — see [Running on AWS](#running-on-aws)

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
- Quantifies gene expression using Salmon
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
| `-h, --help` | Display help message | - | (flag) |

## Output Structure

The pipeline creates a well-organized output directory structure:

```
${outdir}/
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
├── salmon/                      # Expression quantification
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
