# Image for SRA_FASTQ_AWSODP (2_download_fastq/modules/sra_fastq_awsodp/main.nf).
#
# No public image bundles both sra-tools (fasterq-dump) and the AWS CLI, so this builds
# both into one conda environment. Build and push once per AWS_SETUP.md; this is the only
# custom image the AWS migration needs. Verified working end-to-end 2026-08-14: built,
# pushed to ECR, and smoke-tested against a real SRA run (s3 cp --no-sign-request +
# fasterq-dump both succeeded).
#
# Build:
#   docker build -t sra-fastq-awsodp:1.0 docker/sra-fastq-awsodp
# Push (after `aws ecr create-repository --repository-name mapped/sra-fastq-awsodp`):
#   docker tag sra-fastq-awsodp:1.0 <account-id>.dkr.ecr.us-east-1.amazonaws.com/mapped/sra-fastq-awsodp:1.0
#   docker push <account-id>.dkr.ecr.us-east-1.amazonaws.com/mapped/sra-fastq-awsodp:1.0
#
# Then set params.sra_awsodp_container (e.g. via -c or --sra_awsodp_container) to that
# pushed URI, or edit the default in 2_download_fastq/modules/sra_fastq_awsodp/main.nf.

# Two approaches were tried and rejected before this one:
#  1. Installing the AWS CLI directly into the sra-tools biocontainers base via apt-get --
#     that base has no apt-get at all (minimal/unknown package manager).
#  2. Copying a prebuilt AWS CLI binary from AWS's own official CLI image into the
#     sra-tools base via a multi-stage COPY -- the binary is missing a shared library
#     (libz.so.1) in that base, since the two images are built independently with
#     different underlying library versions.
# Installing both tools into the same conda environment instead resolves all their
# dependencies together, consistently: sra-tools=3.1.1 matches the version this replaces
# (biocontainers builds straight from the same bioconda recipe), and conda-forge's
# `awscli` package (currently tracking AWS CLI v2 upstream) supports the
# `aws s3 cp --no-sign-request` call this image's process needs.
FROM mambaorg/micromamba:1.5.8

RUN micromamba install -y -n base -c conda-forge -c bioconda \
      sra-tools=3.1.1 awscli \
    && micromamba clean --all --yes

ENV PATH=/opt/conda/bin:$PATH

RUN aws --version && fasterq-dump --version
