# Image for SRA_FASTQ_AWSODP (2_download_fastq/modules/sra_fastq_awsodp/main.nf).
#
# No public image bundles both sra-tools (fasterq-dump) and the AWS CLI, so this combines
# the two on top of the existing biocontainers sra-tools image. Build and push once per
# AWS_SETUP.md; this is the only custom image the AWS migration needs.
#
# Build:
#   docker build -t sra-fastq-awsodp:1.0 docker/sra-fastq-awsodp
# Push (after `aws ecr create-repository --repository-name mapped/sra-fastq-awsodp`):
#   docker tag sra-fastq-awsodp:1.0 <account-id>.dkr.ecr.us-east-1.amazonaws.com/mapped/sra-fastq-awsodp:1.0
#   docker push <account-id>.dkr.ecr.us-east-1.amazonaws.com/mapped/sra-fastq-awsodp:1.0
#
# Then set params.sra_awsodp_container (e.g. via -c or --sra_awsodp_container) to that
# pushed URI, or edit the default in 2_download_fastq/modules/sra_fastq_awsodp/main.nf.

FROM quay.io/biocontainers/sra-tools:3.1.1--h4304569_2

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl unzip ca-certificates \
    && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/awscliv2.zip /tmp/aws \
    && apt-get purge -y unzip \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

RUN aws --version && fasterq-dump --version
