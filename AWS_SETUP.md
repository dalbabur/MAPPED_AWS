# Running MAPPED on AWS

This guide sets up an AWS environment for MAPPED using **AWS Batch (EC2 Spot-backed) +
S3**, with FASTQ pulled directly from NCBI SRA's AWS Open Data (ODP) buckets instead of
ENA's FTP mirror. It assumes you've already applied the code changes described in the
repo (see `aws.config`, the `awsbatch` profile in each module's `nextflow.config`, and
the new `SRA_FASTQ_AWSODP` process).

Once set up, you run the pipeline exactly as before, just with S3 paths:

```bash
./run_MAPPED.sh \
    --organism "Escherichia coli" \
    --outdir s3://my-mapped-bucket/results \
    --workdir s3://my-mapped-bucket/work \
    --library_layout paired \
    --cpu 16
```

`run_MAPPED.sh` detects the `s3://` prefix and automatically adds `-profile awsbatch` to
every `nextflow run` invocation.

---

## 1. Scope & assumptions

- **Region: `us-east-1`.** NCBI's SRA Open Data buckets (`s3://sra-pub-run-odp`, etc.)
  live in `us-east-1`. Running your own compute and buckets there too avoids
  inter-region data transfer charges and latency. `aws.config` hardcodes this.
- **EC2 Spot-backed AWS Batch, not Fargate.** Nextflow's classic `awsbatch` executor
  stages files to/from S3 by shelling out to the `aws` CLI *inside every job container*.
  With an EC2-backed compute environment you can install the CLI once, on the host, via
  a Launch Template, and bind-mount it into every container (`aws.batch.cliPath` /
  `aws.batch.volumes` in `aws.config`) — none of the ~20 existing task images need to be
  rebuilt. Fargate has no host to bind-mount from, so it would require baking the AWS
  CLI into every image instead. EC2 Spot is also simply cheaper for this workload
  (nothing here is a poor Spot candidate — bacterial genomes are small).
- **Docker images pulled directly from their public registries** (quay.io/biocontainers,
  staphb, Docker Hub) rather than mirrored into ECR. Simplest to start; §7 covers the one
  exception (a small custom image this migration does need) and §12 covers when to
  reconsider (Docker Hub rate-limit throttling).
- You need an AWS account with billing enabled and permission to create IAM roles, VPC
  resources, S3 buckets, and AWS Batch resources (typically `AdministratorAccess` for
  initial setup, scoped down afterward if desired).

---

## 2. Account & region setup

```bash
aws configure set region us-east-1
aws sts get-caller-identity   # confirms your credentials/account
```

Do all of the following in `us-east-1` unless stated otherwise.

---

## 3. IAM

Four distinct roles. Don't collapse them into one broad role — the point of splitting
them is that a compromised or buggy pipeline job can only touch the pipeline's own
bucket prefix, not your whole account.

### 3.1 AWS Batch service role

Lets the Batch service itself manage EC2/Spot capacity on your behalf.

```bash
aws iam create-role --role-name MappedBatchServiceRole \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{ "Effect": "Allow", "Principal": {"Service": "batch.amazonaws.com"}, "Action": "sts:AssumeRole" }]
  }'
aws iam attach-role-policy --role-name MappedBatchServiceRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole
```

### 3.2 Compute environment EC2 instance role

Lets the EC2 instances in the compute environment run the ECS agent that Batch depends
on (pull images, register with ECS, ship logs).

```bash
aws iam create-role --role-name MappedBatchInstanceRole \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{ "Effect": "Allow", "Principal": {"Service": "ec2.amazonaws.com"}, "Action": "sts:AssumeRole" }]
  }'
aws iam attach-role-policy --role-name MappedBatchInstanceRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role
aws iam create-instance-profile --instance-profile-name MappedBatchInstanceProfile
aws iam add-role-to-instance-profile \
  --instance-profile-name MappedBatchInstanceProfile --role-name MappedBatchInstanceRole
```

### 3.3 Batch job role (scoped S3 access for pipeline tasks)

This is the role each **job container** assumes — separate from the instance role above,
so S3 access is scoped to just this pipeline's bucket, not anything else running on the
same EC2 instance. Replace `my-mapped-bucket` with your bucket from §5.

```bash
aws iam create-role --role-name MappedBatchJobRole \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{ "Effect": "Allow", "Principal": {"Service": "ecs-tasks.amazonaws.com"}, "Action": "sts:AssumeRole" }]
  }'

cat > mapped-job-role-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::my-mapped-bucket/*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": "arn:aws:s3:::my-mapped-bucket"
    }
  ]
}
EOF
aws iam put-role-policy --role-name MappedBatchJobRole \
  --policy-name MappedS3Access --policy-document file://mapped-job-role-policy.json
```

No permissions are needed for the SRA ODP read itself — `SRA_FASTQ_AWSODP` uses
`aws s3 cp --no-sign-request`, which bypasses SigV4/credentials entirely for that one
public, anonymous-access bucket.

Point Nextflow at this role by passing `--aws_batch_job_role_arn` (wired up in
`aws.config`'s `aws.batch` block); otherwise jobs fall back to the compute environment's
broader instance role (§3.2):

```bash
./run_MAPPED.sh ... --aws_batch_job_role_arn "arn:aws:iam::$ACCOUNT_ID:role/MappedBatchJobRole"
```

### 3.4 Spot Fleet role

Required by AWS Batch for `SPOT`-type managed compute environments — lets the Spot Fleet
service (not Batch itself) request and tag Spot capacity on your behalf.

```bash
aws iam create-role --role-name MappedSpotFleetRole \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{ "Effect": "Allow", "Principal": {"Service": "spotfleet.amazonaws.com"}, "Action": "sts:AssumeRole" }]
  }'
aws iam attach-role-policy --role-name MappedSpotFleetRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2SpotFleetTaggingRole
```

### 3.5 Head/orchestrator node instance role

The EC2 instance that runs `run_MAPPED.sh`/Nextflow itself needs to submit and monitor
Batch jobs and read/write the same S3 bucket.

```bash
aws iam create-role --role-name MappedHeadNodeRole \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{ "Effect": "Allow", "Principal": {"Service": "ec2.amazonaws.com"}, "Action": "sts:AssumeRole" }]
  }'

cat > mapped-head-node-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::my-mapped-bucket/*"
    },
    { "Effect": "Allow", "Action": ["s3:ListBucket"], "Resource": "arn:aws:s3:::my-mapped-bucket" },
    {
      "Effect": "Allow",
      "Action": [
        "batch:SubmitJob", "batch:DescribeJobs", "batch:ListJobs", "batch:TerminateJob",
        "batch:DescribeJobQueues", "batch:DescribeComputeEnvironments", "batch:DescribeJobDefinitions",
        "batch:RegisterJobDefinition", "batch:DeregisterJobDefinition"
      ],
      "Resource": "*"
    },
    { "Effect": "Allow", "Action": ["logs:GetLogEvents", "logs:DescribeLogStreams"], "Resource": "*" },
    { "Effect": "Allow", "Action": ["ecr:GetAuthorizationToken", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"], "Resource": "*" }
  ]
}
EOF
aws iam put-role-policy --role-name MappedHeadNodeRole \
  --policy-name MappedHeadNodeAccess --policy-document file://mapped-head-node-policy.json
aws iam create-instance-profile --instance-profile-name MappedHeadNodeProfile
aws iam add-role-to-instance-profile \
  --instance-profile-name MappedHeadNodeProfile --role-name MappedHeadNodeRole
```

---

## 4. VPC & networking

You can reuse an existing VPC, or create a small dedicated one. Either way you need at
least one subnet with outbound internet access (for pulling images from quay.io/Docker
Hub and reaching NCBI/ENA for metadata) plus the following endpoints to keep the bulk of
the pipeline's own traffic off the NAT Gateway (S3 traffic — SRA ODP reads, S3
work/outdir staging — is usually the largest volume by far):

```bash
VPC_ID=<your-vpc-id>
ROUTE_TABLE_ID=<your-route-table-id>

# S3 Gateway endpoint — free, covers both the SRA ODP buckets and your own bucket
aws ec2 create-vpc-endpoint \
  --vpc-id "$VPC_ID" --service-name com.amazonaws.us-east-1.s3 \
  --route-table-ids "$ROUTE_TABLE_ID" --vpc-endpoint-type Gateway

# CloudWatch Logs interface endpoint — keeps job log shipping off the NAT Gateway
aws ec2 create-vpc-endpoint \
  --vpc-id "$VPC_ID" --service-name com.amazonaws.us-east-1.logs \
  --vpc-endpoint-type Interface --subnet-ids <private-subnet-ids> \
  --security-group-ids <sg-id>
```

A NAT Gateway (or public subnets with public IPs, simpler but less isolated) is still
needed for image pulls from quay.io/Docker Hub and for Modules 1/3's calls to NCBI
Entrez/`datasets` — those aren't S3 traffic and aren't covered by the endpoints above.

Security group for the compute environment and head node: allow all outbound (default),
no inbound needed for the compute environment; for the head node, allow inbound SSH
(port 22) from your IP only if you'll SSH in directly (Session Manager, §9, avoids
needing this).

---

## 5. S3 layout

```bash
aws s3 mb s3://my-mapped-bucket --region us-east-1
aws s3api put-bucket-versioning --bucket my-mapped-bucket \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket my-mapped-bucket \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
```

Suggested prefixes (matches what `run_MAPPED.sh` expects for `--outdir`/`--workdir`):

```
s3://my-mapped-bucket/results/   <- --outdir
s3://my-mapped-bucket/work/      <- --workdir  (Nextflow's task staging area)
```

### Lifecycle rules (replaces local `--clean-mode`)

`--clean-mode` does local `mv`/`rm -rf` surgery that has no direct S3 equivalent (see
`run_MAPPED.sh`, which now refuses `--clean-mode` combined with `s3://` paths). Use S3
Lifecycle rules instead — safer (no risk of deleting the wrong prefix) and async:

```bash
cat > lifecycle.json <<'EOF'
{
  "Rules": [
    { "ID": "expire-nextflow-work", "Filter": {"Prefix": "work/"}, "Status": "Enabled",
      "Expiration": {"Days": 14} },
    { "ID": "expire-raw-fastq", "Filter": {"Prefix": "results/seqFiles/fastq/"}, "Status": "Enabled",
      "Expiration": {"Days": 30} }
  ]
}
EOF
aws s3api put-bucket-lifecycle-configuration \
  --bucket my-mapped-bucket --lifecycle-configuration file://lifecycle.json
```

Leave `results/expression_matrices/` and `results/samplesheet/` (the equivalent of what
local `--clean-mode` preserves) with no expiration rule.

---

## 6. Launch Template — installing the AWS CLI on compute environment instances

Nextflow's classic `awsbatch` executor requires the `aws` CLI inside every job container
to stage files to/from S3 (see §1). Rather than rebuild all ~20 existing task images, use
an [AWS Batch Launch Template](https://docs.aws.amazon.com/batch/latest/userguide/launch-templates.html)
with user-data that installs the CLI once on the host at instance launch, at the fixed
path `aws.config` expects (`/usr/local/aws-cli`), and bind-mount it into every container.
This also increases the root EBS volume — default sizes are too small once you're
downloading FASTQ + a Salmon index + a reference genome per instance.

```bash
cat > mapped-userdata.sh <<'EOF'
#!/bin/bash
cd /tmp
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -q awscliv2.zip
./aws/install
rm -rf awscliv2.zip aws
EOF

aws ec2 create-launch-template \
  --launch-template-name mapped-batch-lt \
  --launch-template-data "{
    \"UserData\": \"$(base64 -w0 mapped-userdata.sh)\",
    \"BlockDeviceMappings\": [{
      \"DeviceName\": \"/dev/xvda\",
      \"Ebs\": { \"VolumeSize\": 100, \"VolumeType\": \"gp3\", \"DeleteOnTermination\": true }
    }]
  }"
```

This matches `aws.config`:

```groovy
aws.batch.cliPath = '/usr/local/aws-cli/bin/aws'   // path inside the job container
aws.batch.volumes = '/usr/local/aws-cli'           // bind-mounted from the host
```

---

## 7. The one custom image this migration needs

No public image bundles both `sra-tools` (`fasterq-dump`) and the AWS CLI, which
`SRA_FASTQ_AWSODP` (`2_download_fastq/modules/sra_fastq_awsodp/main.nf`) needs together.
Build and push it once to a small private ECR repo:

```bash
aws ecr create-repository --repository-name mapped/sra-fastq-awsodp

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws ecr get-login-password | docker login --username AWS --password-stdin \
  "$ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com"

docker build -t sra-fastq-awsodp:1.0 docker/sra-fastq-awsodp
docker tag sra-fastq-awsodp:1.0 \
  "$ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/mapped/sra-fastq-awsodp:1.0"
docker push "$ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/mapped/sra-fastq-awsodp:1.0"
```

Then point the pipeline at it (either edit the default in
`2_download_fastq/modules/sra_fastq_awsodp/main.nf`, or pass it at runtime):

```bash
./run_MAPPED.sh ... \
  -c <(echo "params.sra_awsodp_container = '$ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/mapped/sra-fastq-awsodp:1.0'")
```

The compute environment's EC2 instance role (§3.2) already includes ECR pull permissions
via `AmazonEC2ContainerServiceforEC2Role`, so no extra IAM is needed for this one image.

---

## 8. AWS Batch compute environment & queue

```bash
aws batch create-compute-environment \
  --compute-environment-name mapped-spot-ce \
  --type MANAGED \
  --state ENABLED \
  --service-role arn:aws:iam::$ACCOUNT_ID:role/MappedBatchServiceRole \
  --compute-resources '{
    "type": "SPOT",
    "allocationStrategy": "SPOT_CAPACITY_OPTIMIZED",
    "minvCpus": 0,
    "maxvCpus": 256,
    "desiredvCpus": 0,
    "instanceTypes": ["optimal"],
    "subnets": ["<private-subnet-id-1>", "<private-subnet-id-2>"],
    "securityGroupIds": ["<sg-id>"],
    "instanceRole": "arn:aws:iam::'"$ACCOUNT_ID"':instance-profile/MappedBatchInstanceProfile",
    "launchTemplate": { "launchTemplateName": "mapped-batch-lt", "version": "$Latest" },
    "spotIamFleetRole": "arn:aws:iam::'"$ACCOUNT_ID"':role/MappedSpotFleetRole"
  }'

aws batch create-job-queue \
  --job-queue-name mapped-spot-queue \
  --state ENABLED \
  --priority 1 \
  --compute-environment-order order=1,computeEnvironment=mapped-spot-ce
```

`minvCpus: 0` lets the compute environment scale to zero (no cost) when nothing is
running — Batch launches Spot instances on demand when jobs are submitted, and
terminates them when the queue empties. `"instanceTypes": ["optimal"]` lets Batch pick
from the current-generation C/M/R families; you can narrow this if you have a strong
preference, but "optimal" generally gets the best Spot availability.

`aws.config`'s `process.queue` must match the queue name (`mapped-spot-queue`, or pass
`--aws_batch_queue <name>` at runtime to override).

---

## 9. Head/orchestrator node

A small instance running `run_MAPPED.sh`/Nextflow itself — it doesn't do heavy
computation (that's delegated to Batch), just orchestration.

```bash
aws ec2 run-instances \
  --image-id <amazon-linux-2023-ami-id> \
  --instance-type t3.medium \
  --iam-instance-profile Name=MappedHeadNodeProfile \
  --subnet-id <subnet-id> \
  --security-group-ids <sg-id> \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":30}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=mapped-head-node}]'
```

On the instance (SSH, or [AWS Systems Manager Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)
if you'd rather not open port 22):

```bash
# Java (Nextflow requires 17+)
sudo yum install -y java-17-amazon-corretto-headless git

# Nextflow
curl -s https://get.nextflow.io | bash
sudo mv nextflow /usr/local/bin/

# AWS CLI (for the sample-count summary / clean-mode-guard branches in run_MAPPED.sh)
sudo yum install -y aws-cli

git clone <your-fork-of-this-repo>
cd MAPPED_AWS
```

**Alternative**: [AWS Cloud9](https://aws.amazon.com/cloud9/) gives you the same thing
(a persistent Linux environment with an IAM role attached) with less EC2 lifecycle
management, if you prefer a managed IDE-style environment over raw EC2.

---

## 10. Nextflow configuration summary

Everything above is wired together through:

- `aws.config` (repo root) — region, `aws.batch.cliPath`/`volumes`/`jobRole`, queue name,
  and per-process cpu/memory/retry tuning.
- Each module's `nextflow.config` — a `profiles { standard { ... } awsbatch { includeConfig "${projectDir}/../aws.config" } }` block. `standard` (local Docker) is Nextflow's
  built-in default when no `-profile` is given, so nothing changes for local runs.
- `run_MAPPED.sh` — auto-detects `s3://` in `--outdir`/`--workdir` and appends
  `-profile awsbatch` to every `nextflow run` call.

You shouldn't need to touch any of these day-to-day; just run `run_MAPPED.sh` with
`s3://` paths once the environment above exists.

---

## 11. Cost controls

- **Spot pricing**: the compute environment (§8) is Spot-first
  (`SPOT_CAPACITY_OPTIMIZED`), typically 60-90% cheaper than on-demand. Combined with
  per-process `errorStrategy`/`maxRetries` in `aws.config`, Spot reclaims are retried
  automatically rather than failing the run.
- **Scale to zero**: `minvCpus: 0` means you pay nothing for compute between runs.
- **S3 Lifecycle rules** (§5): expire `work/` and raw `seqFiles/fastq/` (both
  re-derivable by re-running the pipeline) rather than paying to store them indefinitely.
- **VPC endpoints** (§4): avoid NAT Gateway data-processing charges for S3 and
  CloudWatch Logs traffic — usually the majority of this pipeline's network volume, since
  SRA ODP reads and S3 work-dir staging both go through them.
- **Budget alerts**:
  ```bash
  aws budgets create-budget --account-id "$ACCOUNT_ID" --budget '{
    "BudgetName": "mapped-pipeline", "BudgetType": "COST", "TimeUnit": "MONTHLY",
    "BudgetLimit": {"Amount": "100", "Unit": "USD"}
  }' --notifications-with-subscribers '[{
    "Notification": {"NotificationType":"ACTUAL","ComparisonOperator":"GREATER_THAN","Threshold":80},
    "Subscribers": [{"SubscriptionType":"EMAIL","Address":"you@example.com"}]
  }]'
  ```
- Tag Batch compute resources and the S3 bucket (e.g. `Project=mapped`) and use Cost
  Explorer's tag filter to track spend specifically for this pipeline.

---

## 12. Monitoring & troubleshooting

- **Job logs**: each Batch job ships stdout/stderr to CloudWatch Logs, log group
  `/aws/batch/job`. From the head node: `nextflow log` shows per-task status; the AWS
  Batch console (Jobs → job ID → Logs) shows the raw container output.
- **Common failure signatures**:
  - *Exit code 137 / OOMKilled*: task exceeded its `memory` request — bump the relevant
    `withName`/`withLabel` block in `aws.config`.
  - *Exit code in 130-145, or 104*: Spot interruption — already retried automatically per
    `aws.config`'s `errorStrategy`; if a process fails repeatedly this way, consider
    excluding it from Spot (a second, on-demand-backed queue is the usual pattern, not
    set up by default here since nothing in this pipeline is Spot-fragile).
  - *`RUNNABLE` jobs stuck, never `STARTING`*: usually the compute environment can't find
    matching Spot capacity for the requested vCPU/memory combo, or the launch template
    subnets don't have room — check `aws batch describe-compute-environments`.
  - *Image pull throttling from Docker Hub*: signal to revisit the "pull directly from
    public registries" decision (§1) and add ECR pull-through caching for the affected
    image(s).
- **`nextflow log <run-name> -f status,exit,duration`** on the head node for a quick
  per-task summary of the most recent run.

---

## 13. End-to-end smoke test

Before trusting this on a production-size run, validate the whole chain on a small
organism with few SRA runs:

```bash
./run_MAPPED.sh \
    --organism "Mycoplasma genitalium" \
    --outdir s3://my-mapped-bucket/results-smoketest \
    --workdir s3://my-mapped-bucket/work-smoketest \
    --library_layout paired \
    --cpu 8
```

Check, in order:
1. Step 1 output: `aws s3 cp s3://my-mapped-bucket/results-smoketest/metadata/sample_id.csv -`
   has rows.
2. Step 2 output: `aws s3 ls s3://my-mapped-bucket/results-smoketest/seqFiles/fastq/` shows
   gzipped FASTQ — confirms `SRA_FASTQ_AWSODP` successfully pulled from `sra-pub-run-odp`
   and converted with `fasterq-dump`.
3. Step 3 output: `aws s3 ls s3://my-mapped-bucket/results-smoketest/seqFiles/ref_genome/`
   shows a `.fna`/`.gff` pair.
4. Step 4 output: `aws s3 ls s3://my-mapped-bucket/results-smoketest/expression_matrices/`
   shows `counts.csv`/`tpm.csv`/`log_tpm.csv`/`log_tpm_norm.csv`, and
   `.../samplesheet/samplesheet.csv` has rows — confirms `DATA_VALIDATION` correctly read
   the staged `samplesheet_download.csv` input rather than erroring on a raw S3 path.
5. The `run_MAPPED.sh` "Sample Count Summary" printed to your terminal matches what you
   see in S3.

---

## 14. Explicitly out of scope for this pass

Documented here so it isn't mistaken for an oversight — none of the following is built,
and none is required for the pipeline to run correctly on AWS today:

- **ECR mirroring** of the ~20 existing public images. Revisit if you hit Docker Hub
  anonymous-pull rate limits (§12).
- **Fargate.** Would require baking the AWS CLI into every task image instead of using
  the Launch Template approach in §6.
- **[Nextflow Fusion](https://docs.seqera.io/fusion)**, which would remove the need for
  the AWS-CLI-in-every-container workaround entirely (Fargate becomes viable too), but is
  a Seqera product with its own setup/cost — worth a look once this is running smoothly.
- **Parameterizing the hardcoded `--threads 4`/`-p 4`** in the FastQC/TrimGalore/Salmon
  scripts to actually use `${task.cpus}` — right now, raising `cpus` above 4 for those
  processes in `aws.config` would pay for vCPUs the tools don't use.
