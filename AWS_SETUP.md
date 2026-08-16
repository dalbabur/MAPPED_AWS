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
  a Launch Template, and Nextflow bind-mounts it into every container automatically
  (`aws.batch.cliPath` in `aws.config` — Nextflow derives the mount from this, no separate
  `aws.batch.volumes` needed; see §6 for a duplicate-mount error this caused when both
  were set) — none of the ~20 existing task images need to be rebuilt. Fargate has no host to bind-mount from, so it would require baking the AWS
  CLI into every image instead. EC2 Spot is also simply cheaper for this workload
  (nothing here is a poor Spot candidate — bacterial genomes are small).
- **Docker images pulled directly from their public registries** (quay.io/biocontainers,
  staphb, Docker Hub) rather than mirrored into ECR. Simplest to start; §7 covers the one
  exception (a small custom image this migration does need) and §12 covers when to
  reconsider (Docker Hub rate-limit throttling).
- You need an AWS account with billing enabled and permission to create IAM roles, VPC
  resources, S3 buckets, and AWS Batch resources (typically `AdministratorAccess` for
  initial setup, scoped down afterward if desired).
- **Two different machines show up in this guide, don't conflate them.** Sections 2-8
  (account setup, IAM, VPC, S3, Launch Template, image build/push, Batch compute
  environment/queue) are one-time infrastructure provisioning — run those commands from
  wherever you normally run privileged `aws` CLI commands (typically your own laptop,
  with the AWS CLI installed and an admin-level profile configured). Section 9 creates a
  separate, unprivileged **head node** — that one's for actually running the pipeline
  (`run_MAPPED.sh`/Nextflow) day-to-day, not for provisioning.

---

## 2. Account & region setup

You'll be running commands from (at least) two places: AWS CloudShell or the console
(already authenticated via your AWS login — no setup needed) and your own local machine
(needs the AWS CLI installed and credentials configured, since it has no ambient AWS
login of its own). If your local machine has no working `aws sts get-caller-identity`
yet, create an IAM user and access key for it — do this part from CloudShell/console,
where you're already authenticated:

```bash
aws iam create-user --user-name mapped-admin
aws iam attach-user-policy --user-name mapped-admin \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
aws iam create-access-key --user-name mapped-admin
```

Copy the `AccessKeyId`/`SecretAccessKey` from that last command's output immediately —
the secret is shown only once. Then, on your local machine, in a fresh terminal:

```bash
aws configure   # paste the access key/secret; region: us-east-1
aws sts get-caller-identity   # should now show mapped-admin
```

Once initial setup is done, consider deleting this access key or scoping the user down
(§1 already assumes `AdministratorAccess` only for initial setup, not ongoing use).

```bash
export AWS_DEFAULT_REGION=us-east-1   # takes precedence over ~/.aws/config; also run this
                                       # in any new shell/CloudShell tab you use for later steps
aws configure set region us-east-1
aws sts get-caller-identity   # confirms your credentials/account
aws configure get region      # should print us-east-1 -- if not, see note below
```

Do all of the following in `us-east-1` unless stated otherwise. **If a later command
fails with something like `Endpoint type (Gateway) does not match available service
types ([Interface])`**, that's a symptom of this session actually targeting a different
region (an `AWS_REGION`/`AWS_DEFAULT_REGION` env var, a CloudShell tab pointed elsewhere,
or a named profile with its own region, can all silently override the `configure set`
above) — re-run the `export` line above in that shell and retry.

---

## 3. IAM

Four distinct roles. Don't collapse them into one broad role — the point of splitting
them is that a compromised or buggy pipeline job can only touch the pipeline's own
bucket prefix, not your whole account.

**If a job ever sits `RUNNABLE` with `desiredvCpus > 0` and no EC2 instance shows up**,
read this before anything else. `describe-compute-environments` and `describe-jobs` will
both keep insisting everything is `VALID`/`Healthy` — AWS Batch does not surface the real
error through either of those. The one place it does show up is the Auto Scaling Group
that an EC2-type compute environment creates internally:

```bash
# Find the ASG (name embeds your compute environment's name):
aws autoscaling describe-auto-scaling-groups \
  --query "AutoScalingGroups[?contains(AutoScalingGroupName, '<your-ce-name>')].AutoScalingGroupName" \
  --output text

# Read what it's actually failing on:
aws autoscaling describe-scaling-activities --auto-scaling-group-name <name-from-above> \
  --query 'Activities[?StatusCode==`Failed`].StatusMessage' --output text
```

Two account-wide causes hit while validating this against a live account, both worth
ruling out before digging further into whatever the ASG log actually says:

1. **Missing account-wide service-linked roles.** These are foundational roles AWS
   auto-creates the first time *anything* in the account successfully uses the
   corresponding service — if this account never has, they won't exist, and their
   absence doesn't error, it just silently prevents capacity from ever launching. Two
   were missing here: `AWSServiceRoleForBatch` (Batch's own service-linked role — *not*
   the same as the pipeline-specific `MappedBatchServiceRole` in §3.1 below) and
   `AWSServiceRoleForEC2SpotFleet` (needed specifically for `SPOT`-type compute
   environments). Both are account-wide, not tied to any specific compute environment —
   deleting/recreating the compute environment under a new name will *not* fix a missing
   role. Check and create either:
   ```bash
   aws iam get-role --role-name AWSServiceRoleForBatch
   aws iam create-service-linked-role --aws-service-name batch.amazonaws.com
   aws iam get-role --role-name AWSServiceRoleForEC2SpotFleet
   aws iam create-service-linked-role --aws-service-name spotfleet.amazonaws.com
   ```
2. **Free Tier instance-type restriction** (see §8) — the ASG log's actual failure
   message on this account was `InvalidParameterCombination - The specified instance
   type is not eligible for Free Tier`, from `instanceTypes: ["optimal"]` resolving to
   large current-generation instances (e.g. `r6i.16xlarge`) this account isn't allowed to
   launch. This was the account's *actual* root cause here — the missing service-linked
   roles above were real gaps worth fixing regardless, but fixing them alone didn't
   unblock capacity; the ASG log is what finally showed the real reason.

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
broader instance role (§3.2). **Recommended, not just optional** — the instance role is
scoped for the EC2 host itself (SSM, ECR, tagging, etc.), not S3 object access, so relying
on the fallback typically surfaces later as `AccessDenied`/403 on the job's first S3
write:

```bash
./run_MAPPED.sh ... --aws_batch_job_role_arn "arn:aws:iam::$ACCOUNT_ID:role/MappedBatchJobRole"
```

**Whenever you pass `--aws_batch_job_role_arn`, the *head node's* role also needs
`iam:PassRole` on that job role** — not just the job role needing to exist. AWS Batch
requires the identity that calls `SubmitJob` (here, the head node's `MappedHeadNodeRole`,
via Nextflow) to explicitly be allowed to pass the role it's asking jobs to assume; this
is a standard anti-privilege-escalation control, not specific to this account. Omitting it
surfaces as `iam:PassRole` `AccessDenied` on the very first job submission, *after*
everything else (compute environment, queue, containers) is already working — easy to
mistake for yet another compute environment problem. Add it to §3.5's policy:

```bash
aws iam put-role-policy --role-name MappedHeadNodeRole \
  --policy-name MappedPassBatchJobRole --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{ "Effect": "Allow", "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::'"$ACCOUNT_ID"':role/MappedBatchJobRole" }]
  }'
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
Batch jobs and read/write the same S3 bucket. Include the `batch:TagResource`/
`UntagResource`/`ListTagsForResource` actions below even though they look unrelated to
"submitting jobs" — Nextflow's `awsbatch` executor dynamically registers a job definition
per process/container combo the first time it's needed, and tags it, so `TagResource`
denied here surfaces as an opaque `Error executing process` failure on the *first* job
Nextflow ever submits, not as an obviously-IAM-shaped error.

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
        "batch:RegisterJobDefinition", "batch:DeregisterJobDefinition",
        "batch:TagResource", "batch:UntagResource", "batch:ListTagsForResource"
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

# Required for Session Manager (§9) to connect without opening SSH inbound.
aws iam attach-role-policy --role-name MappedHeadNodeRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam create-instance-profile --instance-profile-name MappedHeadNodeProfile
aws iam add-role-to-instance-profile \
  --instance-profile-name MappedHeadNodeProfile --role-name MappedHeadNodeRole
```

---

## 4. VPC & networking

### 4.1 Simplest path: use your account's default VPC (recommended to start)

Almost every AWS account already has a **default VPC** per region, with public subnets
(one per Availability Zone) that already route to an Internet Gateway — no NAT Gateway
needed, which is the main thing that complicates this section otherwise. Check for one:

```bash
aws ec2 describe-vpcs --filters Name=is-default,Values=true \
  --query 'Vpcs[0].VpcId' --output text
```

If that prints a real VPC ID (not `None`), you already have one — skip to getting its
subnets below. If it prints `None`, create one (works on most accounts; if it errors,
your account/region has no default VPC allowance — create a minimal custom VPC instead
via `aws ec2 create-vpc` + `create-subnet` + `create-internet-gateway` +
`attach-internet-gateway` + a route table entry for `0.0.0.0/0`, or ask an account admin):

```bash
aws ec2 create-default-vpc
```

Then capture the VPC, its public subnets, and a security group as shell variables —
these are reused in §8 (compute environment) and §9 (head node):

```bash
VPC_ID=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true \
  --query 'Vpcs[0].VpcId' --output text)

SUBNET_IDS_JSON=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC_ID" \
  --query 'Subnets[].SubnetId' --output json)
SUBNET_ID=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC_ID" \
  --query 'Subnets[0].SubnetId' --output text)
echo "All subnets (for the Batch compute environment, §8): $SUBNET_IDS_JSON"
echo "First subnet (for single-instance resources like the head node, §9): $SUBNET_ID"

SG_ID=$(aws ec2 create-security-group --group-name mapped-sg \
  --description "MAPPED pipeline (Batch + head node)" --vpc-id "$VPC_ID" \
  --query GroupId --output text)
```

No inbound rules are needed on `$SG_ID` for the Batch compute environment (jobs only
need outbound access, which the security group allows by default). For the head node,
add inbound SSH only if you'll connect that way rather than via Session Manager (§9):

```bash
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
  --protocol tcp --port 22 --cidr "$(curl -s https://checkip.amazonaws.com)/32"
```

Optionally add the S3 Gateway endpoint — it's free, requires no subnet changes, and
reduces both cost and latency for the pipeline's largest traffic source (SRA ODP reads
plus your own S3 work/outdir staging):

```bash
ROUTE_TABLE_ID=$(aws ec2 describe-route-tables \
  --filters Name=vpc-id,Values="$VPC_ID" Name=association.main,Values=true \
  --query 'RouteTables[0].RouteTableId' --output text)

aws ec2 create-vpc-endpoint \
  --vpc-id "$VPC_ID" --service-name com.amazonaws.us-east-1.s3 \
  --route-table-ids "$ROUTE_TABLE_ID" --vpc-endpoint-type Gateway
```

That's enough to run the pipeline. §4.2 below is an optional hardening pass, not a
prerequisite — skip it unless you specifically want the compute environment isolated
from the public internet.

### 4.2 Optional hardening: private subnets + NAT Gateway + interface endpoints

If you'd rather the Batch compute environment's instances not have public IPs at all,
move them into private subnets with a NAT Gateway for internet egress (image pulls from
quay.io/Docker Hub, Modules 1/3's calls to NCBI Entrez/`datasets` — none of that is S3
traffic, so it isn't covered by the S3 endpoint above), plus a CloudWatch Logs interface
endpoint to keep job-log shipping off the NAT Gateway too:

```bash
# CloudWatch Logs interface endpoint (~$0.01/hr per AZ + data processing — skip this in 4.1's simple path)
aws ec2 create-vpc-endpoint \
  --vpc-id "$VPC_ID" --service-name com.amazonaws.us-east-1.logs \
  --vpc-endpoint-type Interface --subnet-ids "<private-subnet-ids>" \
  --security-group-ids "$SG_ID"
```

Setting up the private subnets, NAT Gateway, and route tables themselves is standard VPC
work not specific to this pipeline — see the
[AWS VPC user guide](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html)
if you go this route. If you do, swap `$SUBNET_IDS_JSON`/`$SUBNET_ID` for your private
subnet IDs in §8/§9 below.

---

## 5. S3 layout

`my-mapped-bucket` below is a placeholder — S3 bucket names are globally unique across
*all* AWS accounts, not just yours, so it's almost certainly already taken. Pick a real
name (e.g. `mapped-pipeline-<your-account-id>` is a simple, collision-proof convention)
before running any of this.

**Important, since §3 (IAM) comes before this section:** the job role and head-node role
policies in §3.3/§3.5 were written referencing this same placeholder bucket name, because
this bucket doesn't exist yet at that point in the guide. Once you've created the real
bucket below, go back and re-run those two `put-role-policy` commands with the real
bucket name substituted in — otherwise both roles are scoped to a bucket that doesn't
exist, and Batch jobs/the head node get silent `AccessDenied` errors against the real
one. (This is exactly what happened working through this guide the first time — easy to
miss since nothing errors until you actually try to read/write S3.)

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
s3://my-mapped-bucket/catalog/   <- run/sample discovery index, see §14
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
      "Expiration": {"Days": 30} },
    { "ID": "expire-fastqc", "Filter": {"Prefix": "results/fastqc/"}, "Status": "Enabled",
      "Expiration": {"Days": 30} },
    { "ID": "expire-trimmed", "Filter": {"Prefix": "results/trimmed/"}, "Status": "Enabled",
      "Expiration": {"Days": 30} },
    { "ID": "expire-salmon", "Filter": {"Prefix": "results/salmon/"}, "Status": "Enabled",
      "Expiration": {"Days": 30} },
    { "ID": "expire-multiqc", "Filter": {"Prefix": "results/multiqc/"}, "Status": "Enabled",
      "Expiration": {"Days": 30} }
  ]
}
EOF
aws s3api put-bucket-lifecycle-configuration \
  --bucket my-mapped-bucket --lifecycle-configuration file://lifecycle.json
```

All five expiring prefixes (`fastqc`, `trimmed`, `salmon`, `multiqc`, plus the raw
`seqFiles/fastq`) are re-derivable by re-running the pipeline, matching exactly what
local `--clean-mode` used to delete. Leave `results/expression_matrices/` and
`results/samplesheet/` (the equivalent of what
local `--clean-mode` preserves) with no expiration rule. `catalog/` (§14) is likewise
left with no expiration rule — it's small (metadata rows, not raw data) and is the whole
point of §14, not a disposable intermediate.

---

## 6. Launch Template — installing the AWS CLI on compute environment instances

Nextflow's classic `awsbatch` executor requires the `aws` CLI inside every job container
to stage files to/from S3 (see §1). Rather than rebuild all ~20 existing task images, use
an [AWS Batch Launch Template](https://docs.aws.amazon.com/batch/latest/userguide/launch-templates.html)
with user-data that installs the CLI once on the host at instance launch, at the fixed
path `aws.config` expects (`/usr/local/aws-cli`), and bind-mount it into every container.
This also increases the root EBS volume — default sizes are too small once you're
downloading FASTQ + a Salmon index + a reference genome per instance.

**The AWS CLI v2 installer's real default layout doesn't match the flat path
`aws.config`'s `cliPath` expects** — `./aws/install` actually creates
`/usr/local/aws-cli/v2/<version>/bin/aws`, with `/usr/local/aws-cli/v2/current` symlinked
to the versioned directory and `/usr/local/bin/aws` symlinked to that. There's no literal
`/usr/local/aws-cli/bin/aws`. Running a job with `cliPath` pointing at that nonexistent
flat path fails confusingly *after* everything else works — the instance launches, the
job container starts, and only the actual script command fails, with
`bash: /usr/local/aws-cli/bin/aws: No such file or directory`. Add a compatibility
symlink in the UserData so the simple flat path `cliPath` uses actually resolves, rather
than changing `cliPath` to chase the versioned/symlinked real path (simpler, and avoids
relying on Nextflow's auto-derived container mount correctly following a multi-level
symlink chain):

**UserData must be MIME multipart, not a plain script** — a bare `#!/bin/bash` script
works for standalone EC2 instances, but AWS Batch's compute environment validation
rejects it outright with `CLIENT_ERROR - Launch Template UserData is not MIME multipart
format` (Batch needs to merge its own bootstrap logic in, which requires the well-defined
multipart structure to merge into). Wrap it:

**The launch template must also explicitly request a public IP** — an EC2 instance
launched directly into one of these subnets gets a public IP automatically (default-VPC
subnets have `MapPublicIpOnLaunch` enabled), but instances AWS Batch launches on your
behalf through its own internal Auto Scaling Group do *not* reliably inherit that subnet
default. Without a public IP, the UserData's `curl` to `awscli.amazonaws.com` has no
route out (this VPC has no NAT Gateway — see §4 — and the S3 gateway endpoint only
covers S3 API traffic, not this), so it fails, `./aws/install` never runs, and *nothing*
ends up at `/usr/local/aws-cli` regardless of what the rest of the script says — this
produces the exact same `No such file or directory` symptom described above, and looks
identical to a script bug even though the script itself never got to run. Symptom to
watch for: the compute environment is `VALID`/`Healthy`, an EC2 instance genuinely
launches and the job container starts (so it's *not* the Free Tier or stuck-validation
issues covered elsewhere in this guide), and the job fails immediately on the very first
`aws`-dependent command.

Because `computeResources.securityGroupIds` (at the compute-environment level) and
`NetworkInterfaces` (in the launch template) are mutually exclusive, requesting the
public IP this way means moving the security group into the launch template too, and
dropping it from `create-compute-environment` in §8.

**The ECS-optimized AL2023 AMI doesn't include `unzip`, and "fixing" that by also
installing `curl` breaks the fix.** `unzip awscliv2.zip` fails silently (command not
found) unless you install it first — but AL2023 ships `curl` as the `curl-minimal`
package, which already provides a fully working `curl` binary; explicitly installing the
full `curl` package on top of it *conflicts* with `curl-minimal` and aborts the entire
`yum install` transaction, silently taking `unzip` down with it if they're requested in
the same command (`yum install -y unzip curl` fails outright; the fix that actually kept
matters worse was chaining `|| dnf install -y unzip curl || true` — the `|| true` masked
the failure entirely, so `unzip` silently never got installed either, and the script
carried on to fail identically two steps later at `unzip`). Install *only* `unzip` —
`curl-minimal` is already there and already works:

**The official AWS CLI v2 zip installer's binary dynamically links against the host's
system `libz.so.1` — it does not bundle its own copy.** This is invisible as long as you
only ever run `aws` directly on the host (AL2023 ships `libz` at the OS level, so
`/usr/local/aws-cli/bin/aws --version` works fine there), but every job container gets
`/usr/local/aws-cli` bind-mounted in read-only at launch, and *not every biocontainer
image ships `libz.so.1`* — many of the minimal `quay.io/biocontainers/*` images used by
this pipeline's process modules don't. The job fails immediately with
`error while loading shared libraries: libz.so.1: cannot open shared object file: No such
file or directory` and exit code 127, even though the exact same binary works perfectly
when invoked directly on the host or from a more fully-featured container. This is easy
to misdiagnose as *another* instance of the `cliPath`/mount-layout bug above, since the
symptom (job fails at the first `aws`-dependent command) looks identical — the difference
is in the actual error text, which you'll only see by pulling the job's CloudWatch log
(`aws batch describe-jobs` for the job's `logStreamName`, then `aws logs get-log-events`
against log group `/aws/batch/job`); Nextflow's own log only shows a generic "container
exited"/exit code 127.

**The fix is two parts, and the first alone doesn't work** — copying `libz.so.1` next to
the real binary is necessary but not sufficient. The first attempt at this fix assumed the
PyInstaller-bundled binary uses an `$ORIGIN`-relative rpath (so a same-directory library
would be picked up automatically) — that assumption was wrong and shipped once, silently
failing identically to the original bug. Checked directly against a live instance:
`ldd` on the real `v2/<version>/dist/aws` binary resolves `libz.so.1 => /lib64/libz.so.1`
— the *system* path — even with a copy of `libz.so.1` sitting right next to the binary in
`dist/`. The binary carries no rpath/runpath at all; it relies entirely on the default
system library search path, which is exactly what's missing inside a minimal container.
Verified by reproducing the exact bind-mount scenario with `docker run -v
/usr/local/aws-cli:/usr/local/aws-cli:ro quay.io/biocontainers/biopython:1.79
/usr/local/aws-cli/bin/aws --version` on a standalone EC2 instance built from the same
launch template (outside of Batch, for fast iteration) — this reproduced the failure
in seconds and confirmed the fix before redeploying.

The actual fix: still copy `libz.so.1` into the `dist/` directory (so *something* is
there to find), but also point `LD_LIBRARY_PATH` at that directory whenever `aws` runs.
Since `cliPath` needs to remain a stable flat path but the real binary lives under a
version-numbered directory, make `/usr/local/aws-cli/bin/aws` a small wrapper *script*
(not a symlink) that exports `LD_LIBRARY_PATH` and then `exec`s the real binary:

**Don't write the wrapper via `> /usr/local/aws-cli/bin/aws` if that path is already a
symlink from a previous attempt** — shell output redirection follows symlinks and writes
through to whatever they point at, so `printf ... > bin/aws` silently overwrote the *real*
AWS CLI binary with the wrapper's own text on one contaminated diagnostic instance,
producing an infinite self-exec loop the moment it ran. Harmless here because the
UserData always starts from a fresh, non-symlinked `bin/` directory on every fresh
instance launch — this only bites you if you're hand-patching an already-provisioned
host over SSM, in which case `rm -f`/`unlink` the old symlink first.

```bash
cat > mapped-userdata.sh <<'EOF'
Content-Type: multipart/mixed; boundary="===============MAPPEDBOUNDARY=="
MIME-Version: 1.0

--===============MAPPEDBOUNDARY==
Content-Type: text/x-shellscript; charset="us-ascii"
MIME-Version: 1.0
Content-Transfer-Encoding: 7bit
Content-Disposition: attachment; filename="install-awscli.sh"

#!/bin/bash
exec > /var/log/mapped-userdata.log 2>&1
set -x
yum install -y unzip
cd /tmp
curl -fsSL --max-time 60 "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -o -q awscliv2.zip
./aws/install
REAL_AWS=$(readlink -f /usr/local/aws-cli/v2/current/bin/aws)
AWS_DIST_DIR=$(dirname "$REAL_AWS")
cp -n /usr/lib64/libz.so.1 "$AWS_DIST_DIR/" || true
mkdir -p /usr/local/aws-cli/bin
printf '#!/bin/bash\nexport LD_LIBRARY_PATH=%q\nexec %q "$@"\n' "$AWS_DIST_DIR" "$REAL_AWS" > /usr/local/aws-cli/bin/aws
chmod +x /usr/local/aws-cli/bin/aws
/usr/local/aws-cli/bin/aws --version

--===============MAPPEDBOUNDARY==--
EOF

aws ec2 create-launch-template \
  --launch-template-name mapped-batch-lt \
  --launch-template-data "{
    \"UserData\": \"$(base64 -w0 mapped-userdata.sh)\",
    \"BlockDeviceMappings\": [{
      \"DeviceName\": \"/dev/xvda\",
      \"Ebs\": { \"VolumeSize\": 100, \"VolumeType\": \"gp3\", \"DeleteOnTermination\": true }
    }],
    \"NetworkInterfaces\": [{
      \"DeviceIndex\": 0,
      \"AssociatePublicIpAddress\": true,
      \"Groups\": [\"$SG_ID\"]
    }]
  }"
```

(`exec > /var/log/mapped-userdata.log 2>&1` plus `set -x` gives you somewhere to look if
this ever fails again for a *different* reason — UserData failures otherwise leave no
trace anywhere Batch/CloudWatch surfaces; `describe-compute-environments` and
`describe-jobs` both keep reporting healthy right up until the job fails on the very
first `aws`-dependent command, same as the other silent-failure classes in this guide.
This is genuinely how the `curl`/`unzip` conflict above got found, after the Free-Tier,
public-IP, and path-mismatch fixes all failed to resolve an identical-looking symptom and
guessing further stopped being productive:

1. **`MappedBatchInstanceRole` (§3.2) has no SSM permissions by default** — these worker
   instances aren't manageable via Session Manager out of the box, unlike the head node.
   Attach it temporarily for debugging: `aws iam attach-role-policy --role-name
   MappedBatchInstanceRole --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore`
   (harmless to leave attached afterward too, if you'd rather not detach it later).
2. **Catching an instance before it terminates is the hard part** — a failed job's
   instance can scale back down within under a minute, faster than IAM propagation plus
   SSM agent registration on a *newly launched* instance in many cases. Relaunch the
   smoke test, then poll aggressively (every 5-10s) for a new instance rather than
   waiting: `aws ec2 describe-instances --query 'Reservations[].Instances[] |
   sort_by(@, &LaunchTime) | [-1:]'` catches it by recency across the whole account,
   which proved more reliable here than filtering on the `aws:batch:compute-environment`
   tag (that tag appears to lag or not always apply promptly).
3. Once `aws ssm describe-instance-information --filters Key=InstanceIds,Values=<id>
   --query 'InstanceInformationList[0].PingStatus'` shows `Online`, `aws ssm
   send-command` straight to `cat /var/log/mapped-userdata.log` — this is what actually
   showed the `curl-minimal` conflict error verbatim, immediately, after three prior
   fixes based on plausible-but-wrong guesses.)

**For iterating on a fix itself (as opposed to diagnosing what's broken), skip Batch
entirely** — launch a standalone EC2 instance directly from the same launch template with
`aws ec2 run-instances --launch-template LaunchTemplateName=mapped-batch-lt,Version=<n>`
(needs an explicit `--image-id`, since Batch normally supplies the AMI dynamically via
`ec2Configuration` and the launch template itself doesn't pin one — grab the current
ECS-optimized AL2023 AMI with `aws ssm get-parameter --name
/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended`; also pass
`--iam-instance-profile Name=MappedBatchInstanceProfile` for SSM access, and override the
subnet via `--network-interfaces DeviceIndex=0,SubnetId=<id>` rather than a top-level
`--subnet-id`, which conflicts with the launch template's own `NetworkInterfaces` block).
This gets you a live, SSM-reachable instance in under a minute, running the exact same
UserData/AMI/IAM role a real worker would get, with no dependency on job scheduling timing
or a race against Spot scale-down — you can `ssm send-command` to hand-patch and re-test a
fix repeatedly on the same instance before committing it to a new launch template version.
This is also the only practical way to reproduce a job-container-specific failure (like
the `libz.so.1` issue below) directly: `docker run --rm -v
/usr/local/aws-cli:/usr/local/aws-cli:ro <image> /usr/local/aws-cli/bin/aws --version`
replicates AWS Batch's exact bind-mount behavior in seconds, against the real container
image, without submitting a single Batch job. Terminate the instance when done
(`aws ec2 terminate-instances`) — it's not part of the compute environment and won't be
cleaned up automatically.

**If you fix the UserData on an *existing* launch template used by a compute
environment already stuck `INVALID` with this reason, updating the template alone often
isn't enough** — pushing a new launch template version (even a byte-verified-correct
one) may leave the compute environment reporting the exact same stale `INVALID` status
indefinitely; `update-compute-environment --state ENABLED` (a no-op re-set) and even a
real `ENABLED`→`DISABLED`→`ENABLED` transition don't reliably force re-validation either.
Two additional wrinkles if you go looking for a lighter fix: (a) compute environments
created with a **custom** (non-service-linked) Batch service role — which is what §3.1
sets up — reject `update-compute-environment --compute-resources` changes to
`launchTemplate` entirely (`ClientException: ... can be updated only for ... Compute
Environment having a Batch Service Linked Role`); (b) that's not this repo's setup, so
don't switch service roles just to unblock this. The reliable fix is to disable and
delete both the job queue and the compute environment, then recreate them fresh
(pinning `launchTemplate.version` to the specific corrected version number, not
`$Latest`, removes any ambiguity about which version a fresh create resolves):

```bash
aws batch update-job-queue --job-queue mapped-spot-queue --state DISABLED
# wait for job queue status: DISABLED (poll describe-job-queues)
aws batch delete-job-queue --job-queue mapped-spot-queue
# wait for it to disappear from describe-job-queues, THEN:
aws batch delete-compute-environment --compute-environment mapped-spot-ce
# wait for it to disappear from describe-compute-environments, THEN re-run
# the aws batch create-compute-environment / create-job-queue commands from §8,
# with launchTemplate.version set to your corrected version's literal number.
```

This matches `aws.config`:

```groovy
aws.batch.cliPath = '/usr/local/aws-cli/bin/aws'   // path inside the job container
```

**Don't also set `aws.batch.volumes` to the same path** — Nextflow automatically
bind-mounts `cliPath`'s parent directory from the host into every container; an
additional explicit `volumes` entry for that same path creates two mount points with the
same `containerPath`, which fails at job-submission time with `containerPath values
aren't unique across mountPoints` (opaque — doesn't mention "volumes" or "duplicate" at
all). Hit and fixed against a live account; `aws.config` no longer sets `volumes`. Use
`aws.batch.volumes` only for genuinely *additional* host paths unrelated to the CLI
installation, if you ever need one.

---

## 7. The one custom image this migration needs

No public image bundles both `sra-tools` (`fasterq-dump`) and the AWS CLI, which
`SRA_FASTQ_AWSODP` (`2_download_fastq/modules/sra_fastq_awsodp/main.nf`) needs together.
Build and push it once to a small private ECR repo.

**Needs a real Docker daemon and this repo checked out** — AWS CloudShell does support
Docker, so it works fine here too; just make sure you `git clone` this repo into the
CloudShell session first (`docker build` needs `docker/sra-fastq-awsodp/` to exist in
your current directory — CloudShell's `$HOME` is a separate filesystem from wherever you
edited the repo). Same applies wherever else you run this: your laptop, the head node
(§9), or any CI system.

```bash
aws ecr create-repository --repository-name mapped/sra-fastq-awsodp

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin \
  "$ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com"

docker build -t sra-fastq-awsodp:1.0 docker/sra-fastq-awsodp
docker tag sra-fastq-awsodp:1.0 \
  "$ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/mapped/sra-fastq-awsodp:1.0"
docker push "$ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/mapped/sra-fastq-awsodp:1.0"
```

**Two gotchas hit while validating this (2026-08-14), both worth knowing about:**
- `aws ecr get-login-password` tokens are short-lived. If you `docker build` between
  logging in and pushing (normal — the build can take a few minutes), the token may
  already be stale by push time, failing with `no basic auth credentials`. Just re-run
  the `get-login-password | docker login` line again immediately before `docker push`.
- **On Windows PowerShell specifically**, piping `aws ecr get-login-password` straight
  into `docker login --password-stdin` can silently corrupt the token (fails with
  `400 Bad Request` on login) — a pipe-encoding quirk between the two native processes.
  If that happens, capture the token into a variable first and pass it as an argument
  instead: `$p = (aws ecr get-login-password --region us-east-1).Trim(); docker login --username AWS --password $p <registry>`
  (Docker will warn that `--password` is insecure since it's visible in process
  args/history — fine for this short-lived, low-value token; don't do this for anything
  longer-lived). This isn't an issue in CloudShell/Git Bash/Linux — only Windows
  PowerShell's native-pipe handling triggers it.

Verified working end-to-end against this account: built, pushed, and smoke-tested with a
real SRA run (`aws s3 cp --no-sign-request` + `fasterq-dump` both succeeded, producing
correct paired FASTQ). **The pipeline's default already points at the image pushed
here** (`2_download_fastq/modules/sra_fastq_awsodp/main.nf`) — if you're deploying to a
*different* AWS account, update that default to your own pushed image's URI, or pass
`--sra_awsodp_container <your-uri>` at runtime (note: add it to `run_MAPPED.sh`'s
pass-through flags first, the same way `--aws_batch_queue` is wired up, if you want it as
a CLI flag rather than editing the file).

The compute environment's EC2 instance role (§3.2) already includes ECR pull permissions
via `AmazonEC2ContainerServiceforEC2Role`, so no extra IAM is needed for this one image.

---

## 8. AWS Batch compute environment & queue

Uses `$VPC_ID`/`$SUBNET_IDS_JSON` from §4 and `$ACCOUNT_ID` from §7. **No
`securityGroupIds` here** — §6's launch template already carries the security group via
its `NetworkInterfaces` block (needed for `AssociatePublicIpAddress`), and
`computeResources.securityGroupIds` / launch-template `NetworkInterfaces` are mutually
exclusive; specifying both fails `create-compute-environment` outright:

```bash
COMPUTE_RESOURCES=$(cat <<JSON
{
  "type": "SPOT",
  "allocationStrategy": "SPOT_CAPACITY_OPTIMIZED",
  "minvCpus": 0,
  "maxvCpus": 256,
  "desiredvCpus": 0,
  "instanceTypes": ["optimal"],
  "subnets": $SUBNET_IDS_JSON,
  "instanceRole": "arn:aws:iam::$ACCOUNT_ID:instance-profile/MappedBatchInstanceProfile",
  "launchTemplate": { "launchTemplateName": "mapped-batch-lt", "version": "\$Latest" },
  "spotIamFleetRole": "arn:aws:iam::$ACCOUNT_ID:role/MappedSpotFleetRole"
}
JSON
)

aws batch create-compute-environment \
  --compute-environment-name mapped-spot-ce \
  --type MANAGED \
  --state ENABLED \
  --service-role "arn:aws:iam::$ACCOUNT_ID:role/MappedBatchServiceRole" \
  --compute-resources "$COMPUTE_RESOURCES"

aws batch create-job-queue \
  --job-queue-name mapped-spot-queue \
  --state ENABLED \
  --priority 1 \
  --compute-environment-order order=1,computeEnvironment=mapped-spot-ce
```

If `describe-compute-environments` shows `status: INVALID` afterward, it's almost
certainly the Launch Template's `UserData` format — see §6's troubleshooting note for
the fix, which (importantly) is delete-and-recreate here, not an in-place update.

**On Windows PowerShell**, passing that JSON inline to `--compute-resources` doesn't work
the same way — PowerShell's argument marshaling to native executables strips the quotes
out of an inline JSON string before `aws.exe` ever sees it, producing an
`Invalid JSON: Expecting property name enclosed in double quotes` error. Write it to a
file instead and reference it with `file://`, which sidesteps the quoting entirely
(verified working 2026-08-14):

```powershell
$AWS = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"
$SUBNET_IDS_JSON = (& $AWS ec2 describe-subnets --region us-east-1 --filters Name=vpc-id,Values=$VPC_ID --query 'Subnets[].SubnetId' --output json | Out-String)

$computeResources = @"
{
  "type": "SPOT",
  "allocationStrategy": "SPOT_CAPACITY_OPTIMIZED",
  "minvCpus": 0,
  "maxvCpus": 256,
  "desiredvCpus": 0,
  "instanceTypes": ["optimal"],
  "subnets": $SUBNET_IDS_JSON,
  "instanceRole": "arn:aws:iam::${ACCOUNT_ID}:instance-profile/MappedBatchInstanceProfile",
  "launchTemplate": { "launchTemplateName": "mapped-batch-lt", "version": "`$Latest" },
  "spotIamFleetRole": "arn:aws:iam::${ACCOUNT_ID}:role/MappedSpotFleetRole"
}
"@
$jsonPath = "$env:TEMP\mapped-compute-resources.json"
[System.IO.File]::WriteAllText($jsonPath, $computeResources, [System.Text.UTF8Encoding]::new($false))

& $AWS batch create-compute-environment --region us-east-1 `
  --compute-environment-name mapped-spot-ce --type MANAGED --state ENABLED `
  --service-role "arn:aws:iam::${ACCOUNT_ID}:role/MappedBatchServiceRole" `
  --compute-resources "file://$jsonPath"
```

Note `` `$Latest `` (backtick-escaped) inside the here-string — without it, PowerShell
tries to expand `$Latest` as a variable (and silently substitutes empty string) rather
than passing the literal text AWS Batch expects for "always use the newest launch
template version." The `[System.IO.File]::WriteAllText(...)` with an explicit
no-BOM UTF8 encoding matters too — Windows PowerShell 5.1's `Out-File`/`Set-Content`
default to UTF-8 *with* a BOM, which the AWS CLI's JSON parser chokes on.

`minvCpus: 0` lets the compute environment scale to zero (no cost) when nothing is
running — Batch launches Spot instances on demand when jobs are submitted, and
terminates them when the queue empties. `"instanceTypes": ["optimal"]` lets Batch pick
from the current-generation C/M/R families; you can narrow this if you have a strong
preference, but "optimal" generally gets the best Spot availability.

**Check this account's Free Tier instance-type restriction before trusting `"optimal"`**
— some accounts (this one included) reject every non-Free-Tier-eligible instance type at
the EC2 API level, and `"optimal"`'s C/M/R family pool doesn't include any Free-Tier-
eligible types. The compute environment will report `VALID`/`Healthy` regardless and the
job will simply sit `RUNNABLE` forever with no visible error (see the troubleshooting
note in §3) — this doesn't fail loudly, so check up front:

```bash
aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true \
  --query 'InstanceTypes[].InstanceType' --output text
```

An empty result (or an error) means no restriction — `"optimal"` is fine as-is. A
non-empty list means you're restricted to exactly those types; use that list for
`instanceTypes` instead of `"optimal"`, with two exclusions: any `t4g.*`/ARM entries
(unless you're also using an ARM AMI/launch template, which this guide's §6 isn't), and
**any `t2.*`/`t3.*`/`t3a.*`/`t4g.*` burstable-performance family at all** — AWS Batch's
managed compute environments don't support the T family as an `instanceTypes` value
regardless of Free Tier eligibility (`create-compute-environment` rejects it with a
`ClientException` enumerating the entire set of instance types Batch *does* accept, which
notably contains no `t3.*`/`t2.*` entries anywhere). On the account this was validated
against, the Free Tier list included `t3.micro`/`t3.small`, but those had to be dropped
for this reason, leaving only `c7i-flex.large, m7i-flex.large` — both capping out at
2 vCPU / 8 GiB, which is why `aws.config`'s per-process `cpus`/`memory` directives are
capped at 2 vCPU with a comment explaining why; raise them back
up (and broaden `instanceTypes`) if your account has no such restriction.

`aws.config`'s `process.queue` must match the queue name (`mapped-spot-queue`, or pass
`--aws_batch_queue <name>` at runtime to override).

---

## 9. Head/orchestrator node

A small instance running `run_MAPPED.sh`/Nextflow itself — it doesn't do heavy
computation (that's delegated to Batch), just orchestration.

**Instance type: check Free Tier eligibility first if this account has restrictions.**
`t3.medium` failed here with `InvalidParameterCombination: The specified instance type is
not eligible for Free Tier` on a Free-Tier-restricted account. Check what's actually
eligible before picking one:

```bash
aws ec2 describe-instance-types --region us-east-1 \
  --filters Name=free-tier-eligible,Values=true --query 'InstanceTypes[].InstanceType'
```

`t3.small` (2 GiB RAM) worked and is plenty for orchestration-only work — avoid the
`t4g.*` options in that list if you do this, they're ARM/Graviton and won't match the
x86_64 AMI below.

Uses `$SUBNET_ID`/`$SG_ID` from §4:

```bash
AMI_ID=$(aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameter.Value' --output text)

aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.small \
  --iam-instance-profile Name=MappedHeadNodeProfile \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --associate-public-ip-address \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":30}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=mapped-head-node}]'
```

**On Windows PowerShell**, the same JSON-quoting problem from §8 applies to
`--block-device-mappings`/`--tag-specifications` here too. The fix here is simpler than
§8's file-based workaround: both parameters accept AWS CLI's shorthand syntax instead of
raw JSON, which has no embedded double quotes to get mangled — just wrap each in single
quotes (verified working):

```powershell
--block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=30}' `
--tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=mapped-head-node}]'
```

Give it a couple minutes after `run-instances` before it's reachable — wait for
`aws ec2 wait instance-running`, then, **if you attached the SSM policy from §3.5 after
already creating `MappedHeadNodeRole`** (easy to do if you're working through this guide
non-linearly), double check it's actually attached before assuming Session Manager will
work:

```bash
aws iam list-attached-role-policies --role-name MappedHeadNodeRole
```

An empty result here (role exists, but nothing attached) was the actual root cause the
one time this got stuck — SSM registration silently never happens without it, with no
useful error message pointing at IAM. If you find and fix a missing attachment on an
*already-running* instance, don't just wait — IAM instance profile credentials aren't
always refreshed promptly enough for the SSM agent to notice quickly; terminating and
relaunching (now that the role is correct from boot) is more reliable than waiting
indefinitely for it to pick up the change.

Connect via SSH, or [AWS Systems Manager Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)
if you'd rather not open port 22 (needs `AmazonSSMManagedInstanceCore` on
`MappedHeadNodeRole`, per §3.5 — confirm `aws ssm describe-instance-information
--filters Key=InstanceIds,Values=<id>` shows `PingStatus: Online` before trying to
connect). Non-interactively (e.g. scripting this setup, or from a CLI-only session),
`aws ssm send-command --document-name AWS-RunShellScript` works well and lets you poll
results with `aws ssm get-command-invocation`, without needing an interactive shell at
all — that's how this section was actually validated.

On the instance:

```bash
# Java (Nextflow requires 17+), AWS CLI (for the sample-count summary /
# clean-mode-guard branches in run_MAPPED.sh), and pip (for catalog/register_run.py,
# §14 -- the Java/aws-cli/git trio alone isn't enough once Step 5 is in the mix)
sudo yum install -y java-17-amazon-corretto-headless git aws-cli python3-pip

# Nextflow
curl -s https://get.nextflow.io | bash
sudo mv nextflow /usr/local/bin/

git clone https://github.com/dalbabur/MAPPED_AWS.git
cd MAPPED_AWS

# Packages register_run.py needs (pandas/pyarrow/awswrangler) -- see §14
pip3 install --user -r catalog/requirements.txt
```

**The repo needs to be publicly cloneable for the plain `git clone` above to work
non-interactively** — a private repo fails with `could not read Username for
'https://github.com': No such device or address` (git trying to prompt for credentials
with no terminal to prompt on). Either make the repo public, or use a GitHub
fine-grained, read-only, single-repo access token embedded in the clone URL
(`https://<token>@github.com/...`) if it needs to stay private. If you just flipped a
repo from private to public, give GitHub's edge caches a few seconds — an immediate
clone attempt can still 404/fail once before consistently succeeding.

**Alternative**: [AWS Cloud9](https://aws.amazon.com/cloud9/) gives you the same thing
(a persistent Linux environment with an IAM role attached) with less EC2 lifecycle
management, if you prefer a managed IDE-style environment over raw EC2.

---

## 10. Nextflow configuration summary

Everything above is wired together through:

- `aws.config` (repo root) — region, `aws.batch.cliPath`/`jobRole`, queue name,
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
- **S3 Lifecycle rules** (§5): expire `work/` and all re-derivable intermediate outputs
  (raw `seqFiles/fastq/`, `fastqc/`, `trimmed/`, `salmon/`, `multiqc/`) rather than paying
  to store them indefinitely — only `expression_matrices/`/`samplesheet/` (the actual
  deliverables) are kept with no expiration.
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

## 14. Glue Data Catalog (run/sample discovery index)

Every S3-mode `run_MAPPED.sh` invocation now self-registers into a small Glue Data
Catalog right after Stage 4 completes (`catalog/register_run.py`, invoked as "Step 5" —
see `run_MAPPED.sh`) — a queryable index of every run and sample ever processed into this
bucket, so you can ask "which runs exist for organism X" or "has accession Y already been
processed, and where" without already knowing every `--outdir` anyone has ever used. This
section provisions the Glue database/tables once, admin-side; nothing here is created
lazily by the pipeline itself.

### 14.1 Glue database and tables

One-time, run from wherever you run privileged `aws` CLI commands (same as §2-§8). Both
tables are partitioned by `run_id` and populated directly by `register_run.py` via the
`awswrangler` Python package — **no crawler is used or needed**: each run registers its
own partition at write time (`mode="overwrite_partitions"`), so it's queryable
immediately after Step 5 finishes, with no crawl-lag, and two runs with different
`--outdir` values (hence different `run_id`s) never contend for the same partition even
if they finish at the same time.

```bash
aws glue create-database --database-input '{"Name":"mapped_catalog"}'

cat > mapped-runs-table.json <<'EOF'
{
  "Name": "mapped_runs",
  "StorageDescriptor": {
    "Columns": [
      {"Name": "outdir", "Type": "string"},
      {"Name": "workdir", "Type": "string"},
      {"Name": "organism", "Type": "string"},
      {"Name": "strain", "Type": "string"},
      {"Name": "bioproject", "Type": "string"},
      {"Name": "sra_accessions", "Type": "string"},
      {"Name": "ref_accession", "Type": "string"},
      {"Name": "ref_accession_used", "Type": "string"},
      {"Name": "annotation_version", "Type": "string"},
      {"Name": "library_layout", "Type": "string"},
      {"Name": "quantifier", "Type": "string"},
      {"Name": "cpu", "Type": "int"},
      {"Name": "run_timestamp", "Type": "timestamp"},
      {"Name": "n_samples_downloaded", "Type": "int"},
      {"Name": "n_samples_passed_qc", "Type": "int"},
      {"Name": "aws_batch_queue", "Type": "string"}
    ],
    "Location": "s3://my-mapped-bucket/catalog/runs/",
    "InputFormat": "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat",
    "OutputFormat": "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat",
    "SerdeInfo": {
      "SerializationLibrary": "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }
  },
  "PartitionKeys": [{"Name": "run_id", "Type": "string"}],
  "TableType": "EXTERNAL_TABLE"
}
EOF
aws glue create-table --database-name mapped_catalog --table-input file://mapped-runs-table.json

cat > mapped-samples-table.json <<'EOF'
{
  "Name": "mapped_samples",
  "StorageDescriptor": {
    "Columns": [
      {"Name": "experiment_accession", "Type": "string"},
      {"Name": "sra_run_ids", "Type": "string"},
      {"Name": "organism", "Type": "string"},
      {"Name": "outdir", "Type": "string"},
      {"Name": "quantifier", "Type": "string"},
      {"Name": "bam_path", "Type": "string"},
      {"Name": "run_accession", "Type": "string"},
      {"Name": "sample_accession", "Type": "string"},
      {"Name": "secondary_sample_accession", "Type": "string"},
      {"Name": "study_accession", "Type": "string"},
      {"Name": "secondary_study_accession", "Type": "string"},
      {"Name": "submission_accession", "Type": "string"},
      {"Name": "run_alias", "Type": "string"},
      {"Name": "experiment_alias", "Type": "string"},
      {"Name": "sample_alias", "Type": "string"},
      {"Name": "study_alias", "Type": "string"},
      {"Name": "library_layout", "Type": "string"},
      {"Name": "library_selection", "Type": "string"},
      {"Name": "library_source", "Type": "string"},
      {"Name": "library_strategy", "Type": "string"},
      {"Name": "library_name", "Type": "string"},
      {"Name": "instrument_model", "Type": "string"},
      {"Name": "instrument_platform", "Type": "string"},
      {"Name": "base_count", "Type": "string"},
      {"Name": "read_count", "Type": "string"},
      {"Name": "tax_id", "Type": "string"},
      {"Name": "scientific_name", "Type": "string"},
      {"Name": "sample_title", "Type": "string"},
      {"Name": "experiment_title", "Type": "string"},
      {"Name": "study_title", "Type": "string"},
      {"Name": "sample_description", "Type": "string"},
      {"Name": "fastq_1", "Type": "string"},
      {"Name": "fastq_2", "Type": "string"},
      {"Name": "fastq_md5", "Type": "string"},
      {"Name": "fastq_bytes", "Type": "string"},
      {"Name": "fastq_ftp", "Type": "string"},
      {"Name": "fastq_galaxy", "Type": "string"},
      {"Name": "fastq_aspera", "Type": "string"}
    ],
    "Location": "s3://my-mapped-bucket/catalog/samples/",
    "InputFormat": "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat",
    "OutputFormat": "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat",
    "SerdeInfo": {
      "SerializationLibrary": "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }
  },
  "PartitionKeys": [{"Name": "run_id", "Type": "string"}],
  "TableType": "EXTERNAL_TABLE"
}
EOF
aws glue create-table --database-name mapped_catalog --table-input file://mapped-samples-table.json
```

`base_count`/`read_count` are deliberately `string`, not numeric — `DATA_VALIDATION`
(`4_generate_count_matrix/main.nf`) semicolon-joins them (e.g. `"1234;5678"`) when
multiple SRA runs merge into one experiment, which a numeric Glue type can't hold.
`register_run.py` writes with `schema_evolution=False`, so a genuine mismatch between
what it produces and what's declared here fails loudly at registration time rather than
silently drifting the table.

`bam_path` is the s3:// path(s) to the coordinate-sorted, indexed BAM(s) published under
`<outdir>/bowtie2/` when `--quantifier bowtie2` (the default) was used — the point of
aligning to the whole genome rather than a curated reference is that the BAM is reusable
for analyses beyond gene counting (coverage, variant calling, inspecting non-coding
regions), so this makes those files discoverable without already knowing the `--outdir`.
Semicolon-joined and positionally parallel to `sra_run_ids` for multi-run experiments
(same order, same run tags). Like `ref_accession_used` and the ENA `fastq_*` columns
already in this table, it's constructed from the known publish-path convention, not
verified to exist — a BAM whose alignment/counting step failed for one run of an
otherwise-passing multi-run experiment would still get a path here that 404s. `NULL` for
`--quantifier salmon` runs, which never produce a BAM.

`annotation_version` (`mapped_runs` only) is the NCBI PGAP annotation release actually
used, e.g. `GCF_000007565.2-RS_2025_02_17` — distinct from `ref_accession_used`, since
NCBI can re-run annotation on the same assembly accession (adding/removing genes,
correcting boundaries) without bumping that accession's own version number. Read from
`datasets_summary.json` in Stage 3's output; `NULL` if that record has no RefSeq
annotation (e.g. a GenBank-only `GCA_` accession) or couldn't be resolved.
`filter_processed_samples.py` (`--skip-processed`) matches on this in addition to
`organism`/`ref_accession_used` when available, so a later re-annotation of the same
assembly correctly triggers a re-run instead of being skipped as already processed.

### 14.2 IAM — Glue and Athena access for the head node

`MappedHeadNodeRole` already has full S3 access to the bucket (§3.5), which already
covers writing the new `catalog/` prefix and reading/writing Athena's query-results
prefix — nothing to add there. Add two **new**, separate inline policies (following the
same additive `put-role-policy` pattern §3.3 already uses for `MappedPassBatchJobRole` —
no need to touch the existing `MappedHeadNodeAccess` policy):

**Glue** — scoped to partition/table reads and partition writes only, used by
`register_run.py` (Step 5, every run) and by the Athena queries below (Athena needs Glue
read access to resolve table schemas). Deliberately no
`glue:CreateTable`/`DeleteTable`/`CreateDatabase` — table/database definitions stay
admin-provisioned by §14.1 above; nothing at runtime ever creates or alters them.

```bash
aws iam put-role-policy --role-name MappedHeadNodeRole \
  --policy-name MappedGlueCatalogAccess --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": [
        "glue:GetDatabase", "glue:GetTable", "glue:GetTables",
        "glue:GetPartition", "glue:GetPartitions", "glue:BatchGetPartition",
        "glue:CreatePartition", "glue:BatchCreatePartition",
        "glue:UpdatePartition", "glue:BatchUpdatePartition",
        "glue:DeletePartition", "glue:BatchDeletePartition"
      ],
      "Resource": [
        "arn:aws:glue:us-east-1:'"$ACCOUNT_ID"':catalog",
        "arn:aws:glue:us-east-1:'"$ACCOUNT_ID"':database/mapped_catalog",
        "arn:aws:glue:us-east-1:'"$ACCOUNT_ID"':table/mapped_catalog/mapped_runs",
        "arn:aws:glue:us-east-1:'"$ACCOUNT_ID"':table/mapped_catalog/mapped_samples"
      ]
    }]
  }'
```

**Athena** — needed specifically by `catalog/filter_processed_samples.py` (`--skip-processed`,
`run_MAPPED.sh`), which runs a real SQL query rather than just reading/writing a
partition. Scoped to the `primary` workgroup only:

```bash
aws iam put-role-policy --role-name MappedHeadNodeRole \
  --policy-name MappedAthenaQueryAccess --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": [
        "athena:StartQueryExecution", "athena:GetQueryExecution",
        "athena:GetQueryResults", "athena:GetWorkGroup"
      ],
      "Resource": "arn:aws:athena:us-east-1:'"$ACCOUNT_ID"':workgroup/primary"
    }]
  }'
```

(`$ACCOUNT_ID` here is the same shell variable set in §7 —
`ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)` — re-run that
first if you're in a fresh shell.)

### 14.3 Athena query results location

Athena needs somewhere to write query results before it'll run anything:

```bash
aws athena update-work-group --work-group primary --configuration-updates '{
    "ResultConfigurationUpdates": {"OutputLocation": "s3://my-mapped-bucket/athena-results/"}
  }'
```

### 14.4 Trying it out

After the next `run_MAPPED.sh` invocation against `s3://` paths completes, you should see
a "Step 5: Register run in catalog" block in its output, after Step 4 and before "All
steps completed successfully!". Query what's there — from the Athena console's query
editor, or `aws athena start-query-execution` + `get-query-results` from the CLI:

```sql
-- Which runs exist for organism X
SELECT run_id, outdir, strain, bioproject, run_timestamp, n_samples_passed_qc
FROM mapped_catalog.mapped_runs
WHERE organism = 'Escherichia coli'
ORDER BY run_timestamp DESC;

-- Has SRX14436231 already been processed, and where
SELECT s.run_id, s.experiment_accession, s.outdir, r.run_timestamp
FROM mapped_catalog.mapped_samples s
JOIN mapped_catalog.mapped_runs r ON s.run_id = r.run_id
WHERE s.experiment_accession = 'SRX14436231';

-- Find BAM files for other analyses (coverage, variant calling, etc.) without
-- already knowing which --outdir they came from
SELECT experiment_accession, organism, bam_path
FROM mapped_catalog.mapped_samples
WHERE organism = 'Pseudomonas putida' AND bam_path IS NOT NULL;

-- Browse everything ever processed
SELECT organism, COUNT(DISTINCT run_id) AS n_runs, SUM(n_samples_passed_qc) AS total_samples
FROM mapped_catalog.mapped_runs
GROUP BY organism
ORDER BY n_runs DESC;
```

**Out of scope**: this catalog answers "what exists and where," not "give me one combined
matrix." Merging `expression_matrices/*.csv` across multiple runs of the same organism is
a manual step you'd do yourself, using the `outdir` values these queries return.

---

## 15. Explicitly out of scope for this pass

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
