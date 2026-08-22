# AWS Security & Robustness Audit — MAPPED

Audit date: 2026-08-22. Scope: the AWS environment described in [AWS_SETUP.md](AWS_SETUP.md)
and wired together by `aws.config`, `run_MAPPED.sh`, `catalog/*.py`,
`infra/bootstrap_head_node.sh`, and `docker/sra-fastq-awsodp/Dockerfile`.

## Method

This started as a static review of the IaC-equivalent (the CLI runbook in `AWS_SETUP.md`) and
the application code, because the AWS MCP server's session token had expired. **It was then
re-authorized and a live verification pass was run against the actual account
(347076821446, us-east-1) on 2026-08-22** — see [Live verification pass](#live-verification-pass-2026-08-22)
below for what that confirmed, refuted, or newly surfaced. Findings are marked with their live
status inline; anything not explicitly marked "live-confirmed" or "live-refuted" wasn't checked
against the account (e.g., F1 is a pure code-review finding, and a couple of account-wide
settings, like GuardDuty's exact configuration, were only reachable indirectly).

This live/static split matters because the runbook has already demonstrated it can drift from
reality even in its own text: §5 of `AWS_SETUP.md` documents a past incident where
`MappedBatchJobRole`'s policy was written against a placeholder bucket name and never updated
once the real bucket existed. The live pass below found a new instance of the same class of
problem (see [H1](#h1-live-batch-job-queue-name-doesnt-match-awsconfigs-default)) — the runbook
text and the live account no longer agree on the job queue's name, not just on a historical
placeholder.

Findings are grouped by domain, each using: what was checked and why it matters, the ideal
per AWS guidance, the recommended change, and what it would take to land it (including
whether it can break anything currently working).

---

## Executive summary

| # | Area | Finding | Severity | Breaks anything? | Live status (2026-08-22) |
|---|------|---------|----------|-------------------|---------------------------|
| [A0](#a0-live-this-audit-connection-authenticates-as-the-account-root-user) | IAM | The credential used to run this live audit is the AWS account **root user**, not an IAM identity | High | No — swap credentials, nothing pipeline-related depends on it | 🆕 discovered live |
| [H1](#h1-live-batch-job-queue-name-doesnt-match-awsconfigs-default) | Robustness | Live job queue is `mapped-spot-queue4`; `aws.config` still defaults to `mapped-spot-queue`, which doesn't exist | **Critical** | Fixing it is safe; *not* fixing it means default runs already fail | 🆕 discovered live |
| [A1](#a1-long-lived-admin-access-key-for-mapped-admin) | IAM | `mapped-admin` IAM user with permanent `AdministratorAccess` + long-lived access key | High | No — additive migration | ❌ confirmed live (key active since 2026-08-15) |
| [C3](#c3-github-pat-recommended-to-be-embedded-in-ec2-user-data) | Secrets | Guide's private-repo fallback embeds a GitHub PAT in plaintext EC2 user-data | High | No — swap one line | not live-exploitable today (repo is public) |
| [C1](#c1-imdsv2-not-enforced-on-the-launch-template) | Compute | IMDSv2 enforcement isn't codified in the launch template itself | High→Low | Usually no; verify AWS CLI v2 in the custom image is recent | ⚠️ refuted-in-practice — every running instance already enforces it, but not via anything in the template |
| [E1](#e1-no-cloudtrail) | Audit | No CloudTrail anywhere in the setup | High | No — additive | ❌ confirmed live (zero trails) |
| [A2](#a2-batch-job-role-has-bucket-wide-deleteobject) | IAM | Job role's (and head node role's) `DeleteObject` is scoped to the *entire* bucket, not this run's own prefixes | Medium-High | Yes, if scoping is wrong — needs a prefix audit first | ❌ confirmed live, on both roles |
| [G1](#g1-no-infrastructure-as-code) | Process | Entire environment provisioned via ad hoc CLI commands, no IaC | Medium-High (strategic) | No, if done via import rather than recreate | ❌ confirmed live — orphaned resources found (see below) |
| [D1](#d1-compute-gets-public-ips-by-default) | Network | Head node + Batch instances get public IPs by default; private-subnet hardening is opt-in | Medium | No — `AWS_SETUP.md` §4.2 already covers this path | ❌ confirmed live; inbound rules are empty (better than assumed) |
| [E2](#e2-no-guardduty) | Audit | No GuardDuty | Medium | No — additive | ❌ confirmed live (account has no active detector) |
| [B1](#b1-no-enforce-tls-bucket-policy) | S3 | No bucket policy denying non-TLS requests | Medium | No — every caller already uses HTTPS | ❌ confirmed live (`NoSuchBucketPolicy`) |
| [B4](#b4-no-mfa-delete--object-lock-on-kept-forever-deliverables) | S3 | No MFA Delete / Object Lock on the one prefix meant to be kept forever | Medium | No, if scoped to `expression_matrices/`/`samplesheet/` only | tied to A2's live-confirmed status |
| [C2](#c2-ebs-root-volume-not-explicitly-encrypted) | Compute | Launch template doesn't set `Encrypted: true` on the root EBS volume | Medium | No — transparent to the OS/containers | ❌ confirmed live — all 4 in-use volumes checked are unencrypted |
| [B2](#b2-s3-block-public-access-not-explicitly-set) | S3 | Block Public Access relies on account default, not pinned per-bucket | Medium→**None** | No | ✅ **refuted — already fully enabled on the bucket** |
| [E3](#e3-no-aws-config) | Audit | No AWS Config / drift detection | Medium | No — additive | ❌ confirmed live (zero configuration recorders) |
| [B5](#b5-no-s3-access-logging--cloudtrail-data-events) | S3 | No S3 server access logs or CloudTrail data events on the bucket | Medium | No | ❌ confirmed live (no trail to attach data events to) |
| [C4](#c4-ecr-repo-has-no-image-scanning--immutable-tags) | Compute | ECR repo created without scan-on-push or tag immutability | Low-Medium | No | ❌ confirmed live |
| [C7](#c7-orphaned-disposable-ec2-instance-still-running) | Compute | An undocumented, publicly-addressable EC2 instance has been running since a past debugging session | Medium | No — it's not part of any managed pipeline | 🆕 discovered live |
| [F1](#f1-sql-built-by-string-concatenation-in-athena-queries) | Code | Athena query built by manual quote-escaping, not parameterized | Low-Medium | No — internal function change | not live-checkable (code review only) |
| [B3](#b3-sse-s3-instead-of-sse-kms) | S3 | Default encryption is SSE-S3, not SSE-KMS | Low | No — can be changed non-disruptively | confirmed live, as documented |
| [E4](#e4-cloudwatch-log-group-has-no-retention-policy) | Audit | `/aws/batch/job` log group has no retention policy (grows forever) | Low | No | ❌ confirmed live (no `retentionInDays` set) |
| [A3](#a3-resource–wildcarded-iam-actions-where-avoidable) | IAM | A few IAM actions use `Resource: "*"` where narrower scoping is possible | Low | No | confirmed live, as documented |
| [G2](#g2-no-security-scanning-in-ci) | Process | No Dependabot/CodeQL/container scanning in GitHub Actions | Low | No — additive | not AWS-account-checkable |

Read top-to-bottom for priority; each item below is self-contained if you want to jump straight
to one.

---

## Live verification pass (2026-08-22)

Account `347076821446`, region `us-east-1`. Summary of what changed once checked against the
real account, beyond the inline annotations in the table above:

**Confirmed exactly as predicted:** A1 (mapped-admin's key is active, created 2026-08-15, still
carrying `AdministratorAccess` directly), A2/A3 (both `MappedBatchJobRole` and
`MappedHeadNodeRole`'s inline policies grant bucket-wide `DeleteObject`, read verbatim from
their live policy documents), B1/B5 (no bucket policy, no CloudTrail to attach data events to),
B3 (SSE-S3/AES256 as documented), C2 (checked at the volume level, not just the account
default — all 4 currently-attached EBS volumes, across the compute environment and both head
node instances, show `Encrypted: false`), C4 (ECR repo confirmed `scanOnPush: false`,
`tagMutability: MUTABLE`), E1/E2/E3/E4 (zero CloudTrail trails, GuardDuty has never been
subscribed for this account, zero AWS Config recorders, the batch job log group has no
retention policy set).

**One genuinely good finding:** B2 (S3 Block Public Access) is **already fully enabled** on
`mapped-pipeline-347076821446` — all four settings (`BlockPublicAcls`, `IgnorePublicAcls`,
`BlockPublicPolicy`, `RestrictPublicBuckets`) are `true`. This is very likely the
account-creation-date default described in the original write-up, working as intended — no
action needed here. Also worth noting: the historical bucket-name-placeholder bug documented in
`AWS_SETUP.md` §5 is **not currently recurring** — both IAM policies checked correctly
reference the real bucket name (`mapped-pipeline-347076821446`), not the doc's `my-mapped-bucket`
placeholder.

**One finding that flipped from "gap" to "works, but fragile":** C1 (IMDSv2). Every running
EC2 instance checked — the Batch compute environment's worker instances and both head-node-style
instances — already shows `HttpTokens: required` with `HttpPutResponseHopLimit: 2`, exactly the
hardened configuration this audit was going to recommend. But `mapped-batch-lt`'s own
`LaunchTemplateData` has **no `MetadataOptions` block at all** — the protection isn't coming
from the template. A check of the account-level instance-metadata-defaults setting
(`aws ec2 get-instance-metadata-defaults`) came back without an explicit `HttpTokens` value
either, so the exact mechanism enforcing this isn't fully identified from here — most likely a
current EC2 launch-time default this account happens to benefit from. **Recommendation
downgraded from "fix a gap" to "codify what's already true"**: add the explicit
`MetadataOptions` block to `mapped-batch-lt` anyway, specifically because relying on an
unconfirmed implicit default is itself fragile — nothing in the repo documents *why* these
instances are protected, so a future launch template recreation (which `AWS_SETUP.md` §6
already describes as sometimes necessary) has no guarantee of inheriting it.

**Two new findings, only visible live:**

- **[H1](#h1-live-batch-job-queue-name-doesnt-match-awsconfigs-default)** — a functional/
  robustness bug, not a security one, but the most urgent item in this whole document: the real
  Batch job queue is named `mapped-spot-queue4` (`DescribeJobQueues` returns exactly one queue,
  and that's its name), while `aws.config` line 72 still defaults to `queue =
  params.aws_batch_queue ?: 'mapped-spot-queue'` — no trailing `4`, and no queue by that name
  exists. `AWS_SETUP.md`'s own Quick Start and §13 smoke-test examples never pass
  `--aws_batch_queue`, so run exactly as documented, they'd fail at the first job submission.
- **[C7](#c7-orphaned-disposable-ec2-instance-still-running)** — an EC2 instance named
  `mapped-strain-test-disposable` (t3.small, public IP `3.236.235.147`, state `running`) exists
  outside anything `AWS_SETUP.md` documents, matching the exact "launch a standalone instance
  for fast iteration, terminate when done" pattern the guide describes in §6 — except this one
  was never terminated.

Also worth a mention, tied to [G1](#g1-no-infrastructure-as-code): the live account has **two**
auto-generated `Batch-lt-<uuid>` launch templates alongside the intentional `mapped-batch-lt`,
and the compute environment/job queue names carry a `4` suffix (`mapped-spot-ce4`,
`mapped-spot-queue4`) — both consistent with the "delete and recreate" remediation
`AWS_SETUP.md` §6/§8 describe needing after launch-template `INVALID` states, run more than
once. None of this is a security risk by itself, but it's exactly the kind of small, accumulating
drift that's very hard to catch by reading a CLI runbook and easy to catch with `cdk diff` —
concrete evidence for G1's recommendation, not just a theoretical concern.

---

## H. Robustness (discovered during live verification)

This is placed first, ahead of the security findings, because it's the highest-urgency item in
this document — not because it's the most severe security issue, but because it likely means
the pipeline's own documented default usage doesn't work against this account right now.

### H1 (live). Batch job queue name doesn't match `aws.config`'s default

**What we checked and why:** `AWS_SETUP.md` §8 documents creating a job queue named
`mapped-spot-queue`, and `aws.config` line 72 hardcodes that same name as the fallback when
`--aws_batch_queue` isn't passed: `queue = params.aws_batch_queue ?: 'mapped-spot-queue'`. Live
`DescribeJobQueues` against the actual account returns exactly one job queue, and its name is
**`mapped-spot-queue4`** — not `mapped-spot-queue`. The compute environment backing it is
similarly named `mapped-spot-ce4`, not `mapped-spot-ce`. This strongly matches the "delete and
recreate with the same name" remediation `AWS_SETUP.md` §6/§8 describe for a launch-template
`INVALID` state — plausibly, this environment went through that cycle at least four times, and
at some point the recreated resources picked up disambiguating suffixes (whether from manual
naming during recreation, or an automated retry loop) that never made it back into
`aws.config` or the doc.

**Why this matters:** `run_MAPPED.sh`'s own Quick Start example and the §13 smoke-test example
both invoke the pipeline without `--aws_batch_queue`. Run exactly as documented against this
account, Nextflow's `awsbatch` executor would submit to a job queue name (`mapped-spot-queue`)
that AWS Batch has no record of — this fails at the very first job submission, the same
"opaque, doesn't look IAM/infra-shaped" failure class `AWS_SETUP.md` already warns about
elsewhere (e.g., the `batch:TagResource` gotcha in §3.5).

**Ideal:** The default baked into `aws.config` should always match whatever queue actually
exists in the target account — this is really a symptom of G1 (no IaC keeping the two in sync)
manifesting as a concrete break, not a new category of problem.

**Recommendation:** Immediate fix — update `aws.config`'s default to the real queue name:
```groovy
queue = params.aws_batch_queue ?: 'mapped-spot-queue4'
```
Or, more robustly, treat the queue name as always-required rather than defaulted, so a future
recreation-with-renaming can't silently reintroduce this same class of bug:
```groovy
queue = params.aws_batch_queue ?: { throw new IllegalArgumentException(
    'Pass --aws_batch_queue explicitly (see AWS_SETUP.md §8 for the current queue name)') }()
```
Either way, also correct the queue/compute-environment names referenced in `AWS_SETUP.md` §8
and §13 to match what's actually deployed, or rename the live resources back to the documented
names (`aws batch update-job-queue`/compute environment can't rename in place — this would mean
the same disable/delete/recreate cycle §6 already describes, so simplest is updating the doc
and `aws.config` to match reality, not the reverse).

**Impact if changed:** None to already-running or already-completed work — this only affects
*future* invocations that rely on the default rather than passing `--aws_batch_queue`
explicitly. Editing `aws.config`'s literal string is a one-line, zero-risk change; verify with
the §13 smoke test afterward to confirm a default (no-flag) invocation now succeeds.

---

## A. Identity & Access Management

### A0 (live). This audit connection authenticates as the account root user

**What we checked and why:** The very first live call in this pass —
`aws sts get-caller-identity` — returned `"Arn": "arn:aws:iam::347076821446:root"`. Whatever
credential was set up to authorize the AWS MCP connector for this session is the account's
**root user**, not an IAM user or role. This is a different (and more powerful) credential than
`mapped-admin` (A1) — root can perform account-level actions no IAM policy can grant or deny
(closing the account, changing the support plan, viewing/changing account billing and payment
methods) and, critically, **cannot be restricted by any IAM policy at all**, so it can't be
scoped down the way A1's fix scopes `mapped-admin`.

**Ideal, per AWS guidance:** AWS's own top IAM best practice is to lock away the root user's
credentials and not use them for everyday tasks — ideally not creating a root access key at
all, using the root login (with MFA) only for the small set of tasks that genuinely require it.
See [Root user best practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/root-user-best-practices.html)
and the general
[IAM security best practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html).

**Recommendation:** Reconfigure the AWS MCP connector to authenticate as an IAM identity
instead — either a dedicated IAM user/role scoped to what an AWS-assistant session actually
needs (ideally read-heavy for audits like this one, broader only when you intend to let it make
changes), or short-lived credentials via IAM Identity Center, same pattern as A1's
recommendation. If a root access key currently exists to make this possible, deactivate and
delete it (`aws iam delete-access-key` won't work for root keys via the IAM API the same way —
this has to be done from the account's Security Credentials page, or via
`aws iam list-access-keys`/`update-access-key`/`delete-access-key` if invoked in a root-user
CLI session, which is itself best avoided beyond this one cleanup action) and confirm root has
MFA enabled.

**Impact if changed:** None to the pipeline — this credential isn't referenced anywhere in
`AWS_SETUP.md`, `aws.config`, or any Batch job; it's purely how *this specific assistant
session* was authorized. Swapping it only requires reconfiguring the MCP connector with a
different credential.

---

### A1. Long-lived admin access key for `mapped-admin`

**What we checked and why:** `AWS_SETUP.md` §2 creates an IAM user (`mapped-admin`) with the
AWS-managed `AdministratorAccess` policy attached directly, plus a permanent access key pair,
used for every provisioning command in §2–§14. This is the single most consequential credential
in the whole setup — anyone who obtains it (leaked in a screenshot, committed to a dotfile,
left in shell history, exfiltrated from a compromised laptop) has unrestricted control of the
account, not just this pipeline.

**Ideal, per AWS guidance:** IAM best practice is to avoid IAM users with long-term credentials
for human access entirely, in favor of federated/temporary credentials issued by IAM Identity
Center (AWS SSO) or `sts:AssumeRole`, which expire automatically and never need rotation.
Where a long-lived credential is unavoidable, it should carry the minimum permissions for the
task, not account-wide admin.
See [IAM security best practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)
("Require human users to use federated access... with temporary credentials") and
[IAM Identity Center](https://docs.aws.amazon.com/singlesignon/latest/userguide/what-is.html).

**Recommendation:**
- For ongoing operations, replace `mapped-admin`'s access key with IAM Identity Center
  (`aws configure sso`) or a role assumed via `aws sts assume-role` scoped to exactly the
  services this guide touches (IAM role/policy management, EC2, S3, Batch, Glue, Athena, ECR).
- If a long-lived key must stay for automation (e.g., a CI pipeline that provisions
  infrastructure), scope its policy to those specific services/resources instead of
  `AdministratorAccess`, and rotate it on a schedule (`aws iam list-access-keys` /
  `update-access-key` / `delete-access-key`).
- The guide already says "consider deleting this access key... afterward" — make that
  mandatory, not optional, and add it as an explicit step with a checkbox, since it's the step
  most likely to get skipped under time pressure.

**Impact if changed:** None to the running pipeline — this credential is only used for
provisioning/administration, never referenced by `aws.config`, `run_MAPPED.sh`, or any Batch
job. Deleting or rotating it only affects whoever runs privileged setup commands from their
laptop; they'd need to re-authenticate via the new method next time.

---

### A2. Batch job role has bucket-wide `DeleteObject`

**What we checked and why:** `AWS_SETUP.md` §3.3's `MappedBatchJobRole` policy grants
`s3:GetObject`/`PutObject`/`DeleteObject` on `arn:aws:s3:::my-mapped-bucket/*` — every object in
the entire bucket, not just the prefixes a given run's job containers actually touch. Every job
container across every run and every organism assumes this same role. A compromised or buggy
dependency inside any one of the ~20 third-party biocontainer images (or the custom
`sra-fastq-awsodp` image) could delete any other run's data in that bucket, including the
`expression_matrices/`/`samplesheet/` prefixes the rest of the design treats as permanent
deliverables (see `AWS_SETUP.md` §5, "Left with no expiration rule entirely").

**Ideal, per AWS guidance:** Least privilege — scope resource-level S3 permissions to the
narrowest prefix a role's principal actually needs, not the whole bucket, especially for
destructive actions like `DeleteObject`.
See [Identity and access management for Amazon S3](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-access-control.html)
and the least-privilege guidance in
[IAM best practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html).

**Recommendation:** Scope the policy's `Resource` to the prefixes this pipeline's jobs actually
read/write — `results-*/*`, `work-*/*`, and (if any job writes there directly rather than
through the head node) `catalog/*` — instead of `my-mapped-bucket/*`. Concretely:
```json
{
  "Effect": "Allow",
  "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
  "Resource": [
    "arn:aws:s3:::my-mapped-bucket/results-*",
    "arn:aws:s3:::my-mapped-bucket/work-*"
  ]
}
```
Verify against the actual publish/staging paths in each module's `main.nf` before applying —
narrowing this incorrectly is exactly the kind of change that produces the same silent
`AccessDenied` failure mode `AWS_SETUP.md` §5 already warns about.

**Impact if changed:** **This one can break things if the prefix list is incomplete.** Before
narrowing, grep every module's `publishDir`/output path (`1_download_metadata_efetch`,
`2_download_fastq`, `3_download_reference_genome`, `4_generate_count_matrix`) to confirm the
full set of top-level prefixes jobs write to, including the `by-strain/` nested outdirs
`run_MAPPED.sh` creates for off-strain samples. Roll this out against a smoke-test `--outdir`
first (§13 of `AWS_SETUP.md` already has one) before applying to production runs.

**Live check (2026-08-22):** Confirmed verbatim in both roles' actual policy documents.
`MappedBatchJobRole`'s inline `MappedS3Access` policy grants
`GetObject`/`PutObject`/`DeleteObject` on `arn:aws:s3:::mapped-pipeline-347076821446/*` — the
whole bucket. `MappedHeadNodeRole`'s `MappedHeadNodeAccess` policy carries the identical
bucket-wide grant. One piece of good news found in the same check: both policies correctly
reference the real bucket name — the placeholder-bucket-name bug `AWS_SETUP.md` §5 documents as
a past incident is **not** currently present in either role.

---

### A3. Resource-wildcarded IAM actions where avoidable

**What we checked and why:** `MappedHeadNodeRole`'s inline policy (§3.5) uses
`"Resource": "*"` for `batch:*`, `logs:GetLogEvents`/`DescribeLogStreams`, and
`ecr:GetAuthorizationToken`/`BatchGetImage`/`GetDownloadUrlForLayer`.

**Ideal, per AWS guidance:** Scope IAM resource elements as narrowly as the API allows.

**Recommendation:** Some of these genuinely can't be scoped narrower —
`ecr:GetAuthorizationToken` is documented as requiring `Resource: "*"` (it's an account-level
token, not a per-repository action), and several Batch actions have limited or no
resource-level permission support. But `ecr:BatchGetImage`/`GetDownloadUrlForLayer` can be
scoped to the specific repository ARN (`arn:aws:ecr:us-east-1:$ACCOUNT_ID:repository/mapped/sra-fastq-awsodp`),
and `batch:SubmitJob`/`TerminateJob` can be scoped to the specific job queue ARN. Low priority —
do this as part of the broader IAM cleanup in A1/A2, not on its own.

**Impact if changed:** None expected if scoped correctly (this role only ever touches the one
ECR repo and one job queue today); same "verify before narrowing" caveat as A2.

---

## B. Data Protection (S3)

### B1. No enforce-TLS bucket policy

**What we checked and why:** `AWS_SETUP.md` §5 creates the bucket, enables versioning, and sets
default encryption — but attaches no bucket policy at all. Nothing explicitly rejects requests
made over plain HTTP.

**Ideal, per AWS guidance:** Attach a bucket policy that denies any request where
`aws:SecureTransport` is `false`, so data in transit is protected even if some future client
(a misconfigured script, a third-party tool) doesn't default to HTTPS. See
[Amazon S3 security best practices](https://docs.aws.amazon.com/AmazonS3/latest/userguide/security-best-practices.html).

**Recommendation:**
```bash
aws s3api put-bucket-policy --bucket my-mapped-bucket --policy '{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "DenyInsecureTransport",
    "Effect": "Deny",
    "Principal": "*",
    "Action": "s3:*",
    "Resource": ["arn:aws:s3:::my-mapped-bucket", "arn:aws:s3:::my-mapped-bucket/*"],
    "Condition": {"Bool": {"aws:SecureTransport": "false"}}
  }]
}'
```

**Impact if changed:** None in practice — the AWS CLI, boto3/`awswrangler`, and Nextflow's
`awsbatch` executor all use HTTPS by default already. This only blocks a caller that isn't
using AWS's own tooling correctly, which nothing in this pipeline does.

---

### B2. S3 Block Public Access not explicitly set

**What we checked and why:** The setup guide never calls `put-public-access-block`. New buckets
in accounts created since April 2023 default to Block Public Access enabled account-wide, but
this guide doesn't verify or pin that — an older account, an account where someone previously
disabled the default, or a future bucket created outside this exact runbook could end up
public without anyone noticing (there's no bucket policy granting public access either, so
today's actual exposure is likely low — this is a "make the intent explicit and unable to
regress" fix, not necessarily a live gap).

**Ideal, per AWS guidance:** Explicitly enable all four Block Public Access settings at the
bucket level rather than relying on an account-level default that could be someone else's
change away from being turned off.
See [Blocking public access to your Amazon S3 storage](https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html).

**Recommendation:**
```bash
aws s3api put-public-access-block --bucket my-mapped-bucket --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

**Impact if changed:** None — nothing in this pipeline relies on public bucket access; SRA ODP
reads are *from* a bucket NCBI controls (`sra-pub-run-odp`), not this one, and use
`--no-sign-request` against NCBI's public bucket, unrelated to this setting.

**Live check (2026-08-22):** Already fully enabled — `GetPublicAccessBlock` on
`mapped-pipeline-347076821446` returns all four settings (`BlockPublicAcls`, `IgnorePublicAcls`,
`BlockPublicPolicy`, `RestrictPublicBuckets`) as `true`. **No action needed; this finding is
closed.**

---

### B3. SSE-S3 instead of SSE-KMS

**What we checked and why:** §5 sets default encryption to `AES256` (SSE-S3, AWS-managed keys).
This is a legitimate, AWS-recommended baseline — not a gap by itself — but it means there's no
customer-managed KMS key to attach IAM/key-policy-level access control to, and no CloudTrail
record of individual key-usage events (SSE-S3 key usage isn't logged per-object the way
SSE-KMS is).

**Ideal, per AWS guidance:** SSE-S3 is acceptable for most workloads; SSE-KMS is recommended
when you need a separate access-control layer on the encryption key itself, audit logging of
decrypt events, or cross-account key sharing.
See [Protecting data with server-side encryption](https://docs.aws.amazon.com/AmazonS3/latest/userguide/serv-side-encryption.html).

**Recommendation:** Given this bucket holds no PII/PHI (public SRA accessions and derived
expression data), SSE-S3 is a defensible choice — **treat this as optional**, not a required
fix. If the compliance bar rises later (e.g., this pipeline processes any non-public data), move
to SSE-KMS with a customer-managed key and scope `kms:Decrypt` to exactly the roles in §3.

**Impact if changed:** Switching to SSE-KMS is non-disruptive for existing objects (new writes
pick up the new default; old objects keep their existing encryption) but adds
`kms:GenerateDataKey`/`kms:Decrypt` permission requirements to every role that reads/writes the
bucket (§3.3, §3.5) — would need those added at the same time, or jobs start failing with
`AccessDenied` on the first S3 read/write.

---

### B4. No MFA Delete / Object Lock on "kept forever" deliverables

**What we checked and why:** Versioning is enabled (good — this already protects against
accidental overwrite/delete to some degree, since prior versions survive). But combined with
A2's bucket-wide `DeleteObject` grant, a compromised job container could still issue
version-specific deletes (`DeleteObject` with a `VersionId`) against the one thing the whole
lifecycle design (§5) treats as permanent: `expression_matrices/` and `samplesheet/`.

**Ideal, per AWS guidance:** For data that must survive even a compromised or over-privileged
caller, use MFA Delete (requires the bucket owner's MFA device to permanently delete a version
or change versioning state) or S3 Object Lock (WORM — nothing, including the root user, can
delete before the retention period expires).
See [Configuring MFA delete](https://docs.aws.amazon.com/AmazonS3/latest/userguide/MultiFactorAuthenticationDelete.html)
and [Locking objects with Object Lock](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html).

**Recommendation:** MFA Delete can only be enabled by the bucket owner's root account via CLI
with a hardware/virtual MFA device — heavier operationally, and it applies bucket-wide, not
per-prefix, so it would also slow down the intentional deletes the lifecycle rules already
perform (though lifecycle-driven expirations are exempt from MFA Delete). Object Lock must be
enabled at bucket creation time (cannot be retrofitted) and also applies at the bucket or
object level, not by prefix pattern. Given both are bucket-wide, the more practical fix here is
**A2 (scope `DeleteObject` off the deliverables prefixes entirely for the job role)** — jobs
never legitimately need to delete `expression_matrices/`/`samplesheet/` objects, so removing
that permission achieves the same protection with no operational overhead.

**Impact if changed:** Fixing via A2's prefix-scoping (recommended) has no impact beyond A2's
own caveat. If you separately want Object Lock, it requires a new bucket (can't be added to
`my-mapped-bucket` after the fact) and a data migration — significant enough that it should be
a deliberate follow-up decision, not bundled into this pass.

---

### B5. No S3 access logging / CloudTrail data events

**What we checked and why:** Nothing in the guide enables S3 server access logging or
CloudTrail data-event logging for the bucket. Today, if data were deleted or read unexpectedly,
there'd be no way to answer "who/what did this and when" beyond CloudTrail's default
*management*-event logging (which doesn't cover object-level `GetObject`/`PutObject`/
`DeleteObject` calls).

**Ideal, per AWS guidance:** Enable either S3 server access logging (simpler, logs to another
bucket) or CloudTrail data events for S3 (richer, integrates with the rest of CloudTrail) so
object-level activity is auditable.
See [Logging requests using server access logging](https://docs.aws.amazon.com/AmazonS3/latest/userguide/ServerLogs.html).

**Recommendation:** Bundle this with E1 (CloudTrail) below — enabling a trail with S3 data
events covers this in one step rather than standing up server access logging separately.

**Impact if changed:** None — purely additive logging, no effect on pipeline behavior. Ongoing
cost is small at this data volume but non-zero (data events are billed per event).

---

## C. Compute (EC2 / AWS Batch)

### C1. IMDSv2 not enforced on the launch template

**What we checked and why:** The launch template in `AWS_SETUP.md` §6
(`create-launch-template`) sets `UserData`, `BlockDeviceMappings`, and `NetworkInterfaces`, but
no `MetadataOptions`. By default this leaves IMDSv1 available alongside v2. IMDSv1 is the
well-known vector for SSRF-to-credential-theft (an attacker who can make the instance issue an
HTTP request to `169.254.169.254` — e.g., via a vulnerable dependency in one of the ~20
third-party biocontainer images this pipeline runs — can retrieve the instance role's temporary
credentials with a single unauthenticated GET, no token required).

**Ideal, per AWS guidance:** Set `HttpTokens=required` (IMDSv2 only) on every launch template.
This is called out explicitly in this account's own EC2 guidance:
*"Enforce IMDSv2 (`HttpTokens=required`) on launch templates to block SSRF-based credential
theft."* See
[EC2 instance metadata and user data](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-metadata.html)
and [Amazon EC2 security best practices](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-security.html).

**Recommendation:** Add to the launch template's `LaunchTemplateData`:
```json
"MetadataOptions": {
  "HttpTokens": "required",
  "HttpPutResponseHopLimit": 2,
  "HttpEndpoint": "enabled"
}
```
Note `HttpPutResponseHopLimit: 2`, not the default of `1` — because job containers run one
network hop away from the host, the default hop limit makes the IMDSv2 token request fail to
reach a containerized process (this is documented as a known gotcha, not a guess). With
`HttpTokens=required` and the default hop limit, containers would get silent, hard-to-diagnose
`401`s trying to reach IMDS — exactly the kind of failure mode `AWS_SETUP.md` already has
several examples of (the launch-template UserData issues in §6).

**Impact if changed:** Low risk, but verify before applying: this pipeline's containers rely on
the bind-mounted AWS CLI (v2, installed fresh by the launch template's own UserData) for S3
access, and AWS CLI v2 and recent boto3 both support IMDSv2 natively — should be transparent.
The one thing genuinely worth testing first: confirm none of the ~20 third-party biocontainer
images (not built by this project) bundle an old AWS SDK that only speaks IMDSv1 — unlikely
given none of them appear to call AWS APIs directly (only the bind-mounted host CLI does), but
worth a smoke test (§13) before rolling out broadly, specifically checking that
`SRA_FASTQ_AWSODP` (the one image that does call `aws s3 cp`) still succeeds.

**Live check (2026-08-22):** Every currently-running instance already shows
`HttpTokens: required`/`HttpPutResponseHopLimit: 2` — so in practice this protection is already
in effect account-wide. But `mapped-batch-lt`'s own `LaunchTemplateData` has no `MetadataOptions`
block, so nothing in the reviewable IaC-equivalent explains *why*. Treat the recommendation
below as "make the existing protection explicit and auditable," not "close an active gap" — the
risk if left as-is isn't that IMDSv1 is reachable today, it's that nothing guarantees it stays
that way (a future `mapped-batch-lt` recreation — which §6/§8 already describe sometimes being
necessary — inherits whatever the template says, not whatever happened to be true before).

---

### C2. EBS root volume not explicitly encrypted

**What we checked and why:** The launch template's `BlockDeviceMappings` (§6) sets
`VolumeSize`, `VolumeType`, and `DeleteOnTermination`, but no `Encrypted` flag. Whether the
resulting volume ends up encrypted depends entirely on whether "EBS encryption by default" is
enabled at the account/region level — not verified here (would need live-account access).

**Ideal, per AWS guidance:** Encrypt EBS volumes and AMIs; don't rely on an implicit
account-level default that could be off.
See [Amazon EBS encryption](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/EBSEncryption.html).

**Recommendation:** Either enable the account-level default
(`aws ec2 enable-ebs-encryption-by-default --region us-east-1`, a one-time account/region
setting — recommended, since it also covers the head node's volume and any future instances),
or add `"Encrypted": true` explicitly to the launch template's `BlockDeviceMappings` entry.

**Impact if changed:** None — EBS encryption is transparent to the OS and every process running
on top of it, including Docker and the AWS CLI. No performance-relevant difference at this
scale.

**Live check (2026-08-22):** Confirmed at the volume level, not just the account default —
`DescribeVolumes` shows all 4 currently in-use volumes (two 100 GiB compute-environment
volumes, the 30 GiB head node volume, and one 8 GiB volume) with `Encrypted: false`. The
account-wide `GetEbsEncryptionByDefault` setting is also confirmed `false`, consistent with
that. This is a live, active gap — not a hypothetical one.

---

### C3. GitHub PAT recommended to be embedded in EC2 user-data

**What we checked and why:** `AWS_SETUP.md` §9 and `infra/bootstrap_head_node.sh`'s header
comment both document, as the supported alternative to a public repo, embedding a GitHub
fine-grained PAT directly into `REPO_URL` (`https://<token>@github.com/...`) inside the
bootstrap script that gets passed as EC2 `--user-data`. EC2 user-data is **not a secret store**:
it's readable in plaintext by anyone who can call
`ec2:DescribeInstanceAttribute --attribute userData` against the instance (a much lower bar
than full account access — many read-only/support IAM policies grant this), and it's also
readable in plaintext from inside the instance itself at `/var/lib/cloud/instance/user-data.txt`
by any process or user with local access, not just root.

**Ideal, per AWS guidance:** Never embed credentials in user-data. Store secrets in AWS Secrets
Manager and resolve them at runtime.
See [What is AWS Secrets Manager?](https://docs.aws.amazon.com/secretsmanager/latest/userguide/intro.html).
This is exactly the class of risk this repo's own `CLAUDE.md` already calls out under "Secret
Safety" — this finding is the concrete instance of that policy inside this codebase.

**Recommendation:** If the repo needs to stay private, store the PAT in Secrets Manager instead
and have the bootstrap script resolve it at boot, e.g.:
```bash
GITHUB_PAT=$(aws secretsmanager get-secret-value --secret-id mapped/github-pat \
  --query SecretString --output text --region us-east-1)
REPO_URL="https://${GITHUB_PAT}@github.com/dalbabur/MAPPED_AWS.git"
```
plus a scoped `secretsmanager:GetSecretValue` grant on that one secret ARN added to
`MappedHeadNodeRole`. (Per this repo's `CLAUDE.md`, resolving secrets this way — or via the
`{{resolve:secretsmanager:...}}` dynamic-reference pattern where the target supports it — is
the required pattern; don't fetch the secret value into a general-purpose script variable and
log/echo it anywhere.) Today, though, the repo *is* public (the plain `git clone` in
`bootstrap_head_node.sh` works precisely because no token is needed) — so the actual live
exposure right now is likely nil. This finding is about not regressing if/when the repo goes
private, and about not leaving embedded-token guidance as the documented "supported" path in
`AWS_SETUP.md`/the script's own header comment.

**Impact if changed:** None while the repo stays public — this is a documentation/guidance fix,
not an active remediation. If/when the repo goes private, this becomes the required path rather
than the embedded-token alternative currently documented.

---

### C4. ECR repo has no image scanning / immutable tags

**What we checked and why:** §7's `aws ecr create-repository --repository-name
mapped/sra-fastq-awsodp` doesn't set `--image-scanning-configuration scanOnPush=true` or
`--image-tag-mutability IMMUTABLE`. This is the one custom image in the pipeline (everything
else pulls from public registries per §1's documented decision) — low blast radius, but it's
the one image this project actually controls the build of, so it's the cheapest place to get
this right.

**Ideal, per AWS guidance:** Enable scan-on-push (uses Amazon ECR's basic scanning, based on
Clair) to catch known CVEs in the base image/dependencies, and set tag immutability so a
`:1.0` tag can't be silently repointed at a different image later (supply-chain integrity).
See [Image scanning](https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-scanning.html)
and [Image tag mutability](https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-tag-mutability.html).

**Recommendation:**
```bash
aws ecr create-repository --repository-name mapped/sra-fastq-awsodp \
  --image-scanning-configuration scanOnPush=true \
  --image-tag-mutability IMMUTABLE
```
For an already-existing repo: `aws ecr put-image-scanning-configuration` and
`aws ecr put-image-tag-mutability` apply the same settings retroactively.

**Impact if changed:** None to existing pushed images. Tag immutability means a future rebuild
must push a new tag (`:1.1`, etc.) rather than overwriting `:1.0` — a minor workflow change, not
a break, and arguably desirable given `2_download_fastq/modules/sra_fastq_awsodp/main.nf`
hardcodes a specific tag as its default.

---

### C5. Head node is a single point of failure (informational)

**What we checked and why:** §9 launches one `t3.small` EC2 instance for orchestration, with no
Auto Scaling group, no EC2 Auto Recovery alarm, and no multi-AZ consideration.

**Ideal, per AWS guidance:** For workloads that need to survive an instance/AZ failure
automatically, use an Auto Scaling group (even a size-1 one, for auto-replace) or a CloudWatch
alarm wired to EC2 Auto Recovery.

**Recommendation:** Given the head node only orchestrates (all heavy compute is delegated to
Batch, per §9's own framing) and Nextflow's `-resume` against the S3 work-dir already provides
resilience to *restarting* orchestration from where it left off, a full standalone instance is
plausibly an acceptable, deliberate simplicity trade-off here — **not flagging this as a
required fix**, just noting it as a known gap if head-node availability ever becomes a real
constraint (e.g., long-running compendium-scale runs where losing the head node mid-run is
costly to restart).

**Impact if changed:** N/A — no change recommended at this time.

---

### C7. Orphaned "disposable" EC2 instance still running

**What we checked and why:** Live `DescribeInstances` turned up a `t3.small` instance named
`mapped-strain-test-disposable` (instance ID `i-03494cd670d8b3866`), state `running`, with a
public IP (`3.236.235.147`). Nothing in `AWS_SETUP.md` documents this instance. Its name and
type closely match the exact pattern the guide itself describes in §6 for fast local
iteration — *"launch a standalone EC2 instance directly from the same launch template... for
iterating on a fix... Terminate the instance when done... it's not part of the compute
environment and won't be cleaned up automatically"* — strongly suggesting this was a debugging
instance from a past session (plausibly related to the recent off-strain-detection work,
given the name) that was never terminated per that guidance.

**Why this matters:** It's a running, internet-addressable, billed EC2 instance that isn't
tracked anywhere — not in `AWS_SETUP.md`, not part of the Auto Scaling group backing the
compute environment, and (unless manually confirmed) potentially carrying whatever IAM role and
security group it was launched with from that debugging session, possibly with looser
constraints than a properly reviewed permanent resource would get. It's also a straightforward
cost leak (small for a `t3.small`, but avoidable).

**Recommendation:** Confirm with whoever ran that debugging session whether it's still needed;
if not:
```bash
aws ec2 terminate-instances --instance-ids i-03494cd670d8b3866 --region us-east-1
```
If it does need to stick around for ongoing work, at minimum rename it to something that won't
read as disposable, and document why it exists.

**Impact if changed:** None to the actual pipeline — this instance sits outside the Batch
compute environment and the head node role's responsibilities entirely. Terminating it can't
affect any in-flight or `-resume`-able run.

---

## D. Network

### D1. Compute gets public IPs by default

**What we checked and why:** §4.1 (the documented default path) uses the account's default VPC
with public subnets; the launch template explicitly requests `AssociatePublicIpAddress: true`
(§6, needed because Batch-launched instances don't reliably inherit the subnet's own
public-IP-on-launch default), and the head node also gets `--associate-public-ip-address`
(§9). Inbound is safe (no open ports by default; SSH, if enabled at all, is scoped to the
caller's own `/32`), but every compute instance in this design is directly reachable from the
internet at the network layer, with only security-group rules as the barrier.

**Ideal, per AWS guidance:** Well-Architected's Security Pillar favors placing compute that
doesn't need to be internet-facing into private subnets, with a NAT Gateway (or VPC endpoints,
for AWS-service-only egress) for outbound access — reducing the network attack surface even
when security groups are correctly locked down, since it removes an entire class of
misconfiguration risk (an accidentally-opened security group rule on a private-subnet instance
is far less exploitable than the same mistake on a publicly-addressable one).

**Recommendation:** `AWS_SETUP.md` §4.2 already documents this exact hardening path (private
subnets + NAT Gateway + a CloudWatch Logs interface endpoint) and correctly scopes it as
optional rather than required. **This audit agrees with that framing** — it's a legitimate,
already-considered cost/complexity trade-off (NAT Gateway has an hourly + per-GB cost), not an
oversight. The recommendation is simply to graduate to §4.2 once cost is less of a concern, or
sooner if this account ever processes non-public data.

**Impact if changed:** Moving to §4.2 requires swapping `$SUBNET_IDS_JSON`/`$SUBNET_ID` for
private subnet IDs and adding the NAT Gateway + CloudWatch Logs interface endpoint — §4.2
already notes this. Test with the §13 smoke test before switching production traffic, since
outbound paths for non-S3 traffic (Docker Hub/quay.io image pulls, NCBI Entrez/`datasets` API
calls in Modules 1/3) all start routing through the NAT Gateway instead of directly, and any
missed interface endpoint or route-table gap would manifest as image-pull or metadata-fetch
timeouts.

---

## E. Observability & Audit

### E1. No CloudTrail

**What we checked and why:** Nothing in `AWS_SETUP.md` enables a CloudTrail trail. Given this
account, by this same guide's own §2, mints a permanent `AdministratorAccess` access key, and
every subsequent section creates IAM roles/policies, security groups, and compute resources —
having no audit trail of who did what, when, is a significant blind spot for an account with
that level of standing privilege in play.

**Ideal, per AWS guidance:** Enable a multi-region CloudTrail trail, delivered to a
dedicated, access-restricted S3 bucket (ideally a different bucket/account than the one holding
pipeline data), so account-level API activity is durably logged and available for incident
investigation.
See [AWS CloudTrail User Guide](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-user-guide.html).
Also confirmed directly in this account's own EC2 guidance: *"Enable CloudTrail in all Regions
to audit EC2/ASG/SSM API activity, and alarm on sensitive actions."*

**Recommendation:**
```bash
aws cloudtrail create-trail --name mapped-account-trail \
  --s3-bucket-name mapped-cloudtrail-logs-$ACCOUNT_ID --is-multi-region-trail
aws cloudtrail start-logging --name mapped-account-trail
```
Use a **separate** bucket from `my-mapped-bucket` (mixing audit logs with pipeline data
complicates both the lifecycle rules in §5 and the access-control story for the logs
themselves). Optionally add S3 data events for `my-mapped-bucket` on the same trail to also
cover B5 above.

**Impact if changed:** None to the pipeline — purely additive. Ongoing cost: one free
management-event trail per account/region; data events (if added for B5) are billed per event,
small at this data volume.

---

### E2. No GuardDuty

**What we checked and why:** No threat-detection service is enabled anywhere in the setup.
GuardDuty analyzes CloudTrail, VPC Flow Logs, and DNS logs (auto-provisioned internally, no
separate setup needed for those inputs) to surface things like compromised-credential use
patterns, cryptomining on EC2, or anomalous API calls — exactly the class of incident a
publicly-reachable, third-party-image-running compute environment (C1, D1) is most exposed to.

**Ideal, per AWS guidance:** Enable GuardDuty account-wide as a baseline threat-detection layer.
See [What is Amazon GuardDuty?](https://docs.aws.amazon.com/guardduty/latest/ug/what-is-guardduty.html).

**Recommendation:**
```bash
aws guardduty create-detector --enable --region us-east-1
```
Pair with an EventBridge rule + SNS topic (or the budget email from §11) to actually get
notified of findings, rather than only checking the console reactively.

**Impact if changed:** None to the pipeline — fully out-of-band. GuardDuty has a cost based on
CloudTrail event volume and VPC Flow Log volume analyzed; check current pricing before enabling
if budget (§11) is a hard constraint.

---

### E3. No AWS Config

**What we checked and why:** No configuration-history or compliance-rule service is enabled.
Given this guide has already produced real drift once (the bucket-name mismatch in §5) and
documents multiple failure modes that are "silent" by design (compute environment reports
`VALID`/`Healthy` while jobs never actually run — §3, §6, §8), a service that continuously
records resource configuration and can alert on drift from an expected baseline would directly
address the class of problem this guide keeps running into.

**Ideal, per AWS guidance:** AWS Config records configuration changes over time and can evaluate
resources against managed or custom rules (e.g., "S3 buckets must have versioning enabled",
"EBS volumes must be encrypted").
See [What Is AWS Config?](https://docs.aws.amazon.com/config/latest/developerguide/WhatIsConfig.html).

**Recommendation:** Lower priority than E1/E2 — most valuable once the environment is under
IaC (G1), since Config's real power here is catching *manual* drift from the IaC-defined
baseline. If adopted now (pre-IaC), start with a small rule set targeting exactly the gaps this
audit found: `s3-bucket-public-read-prohibited`, `s3-bucket-server-side-encryption-enabled`,
`encrypted-volumes`, `iam-user-no-policies-check` (flags policies attached directly to users
like `mapped-admin`, reinforcing A1).

**Impact if changed:** None to the pipeline — additive and read-only unless you also configure
auto-remediation (not recommended to start).

---

### E4. CloudWatch log group has no retention policy

**What we checked and why:** `AWS_SETUP.md` §12 notes Batch job logs ship to
`/aws/batch/job`. Neither this guide nor the AWS default sets a retention period on that log
group — CloudWatch Logs groups are created with **never-expire** retention unless explicitly
set, so job logs (which include full script stdout/stderr for every task, across every run,
indefinitely) accumulate storage cost forever.

**Ideal, per AWS guidance:** Set an explicit retention period matched to how long job logs are
actually useful for debugging (§12 already frames these as short-term troubleshooting aids, not
long-term deliverables — that's what the Glue catalog in §14 is for).

**Recommendation:**
```bash
aws logs put-retention-policy --log-group-name /aws/batch/job --retention-in-days 30
```
30 days roughly matches the 14-day work-dir / 30-day BAM-to-Glacier windows already chosen
elsewhere in §5's lifecycle design, for consistency.

**Impact if changed:** None to running jobs — only affects how long past logs are retained, not
current job execution or logging.

---

## F. Application / Code-Level

### F1. SQL built by string concatenation in Athena queries

**What we checked and why:** `catalog/filter_processed_samples.py` builds its Athena query by
manually escaping single quotes (`args.organism.replace("'", "''")`) and splicing the result
directly into an f-string SQL query, rather than using parameterized/bound query execution.

**Ideal, per AWS guidance:** Defense-in-depth coding practice is to avoid manual string-escaping
for query construction wherever a parameterized alternative exists, since manual escaping is
easy to get subtly wrong (e.g., it handles `'` but not other dialect-specific metacharacters)
and the risk compounds if this code's trust boundary ever changes.

**Recommendation:** Today, `--organism`/`--ref-accession-used`/`--annotation-version` come from
the pipeline operator's own CLI invocation (propagated from `run_MAPPED.sh`, itself run by
whoever operates the head node) — not from an external or multi-tenant input, so the practical
injection risk right now is low. Still worth tightening given how cheap the fix is: validate
these inputs against an allow-list pattern (organism names and accessions have a predictable
shape) before interpolation, as a defense-in-depth measure independent of the current trust
level. Flag this explicitly if this pipeline is ever fronted by a shared service or web UI that
accepts these values from less-trusted callers — at that point this becomes a must-fix, not a
nice-to-have.

**Impact if changed:** None — purely internal to `filter_processed_samples.py`, no interface
change, no infrastructure impact.

---

## G. Process / Strategic

### G1. No Infrastructure-as-Code

**What we checked and why:** The entire AWS environment — IAM roles/policies, VPC/security
group, S3 bucket, launch template, Batch compute environment/queue, ECR repo, Glue
database/tables — is provisioned by manually running ~100 individual `aws` CLI commands
documented in a 1,445-line runbook. This repo's own `CLAUDE.md` already states the policy this
finding is checking compliance against: *"When creating infrastructure, prefer
infrastructure-as-code (AWS CDK or CloudFormation) over direct CLI commands."*

This is worth calling out as the **root cause** behind several other findings and behind every
"drift" incident `AWS_SETUP.md` documents fixing after the fact: the bucket-name/IAM-policy
mismatch (§5), the launch-template `INVALID` state requiring manual delete-and-recreate rather
than update (§6, §8), and the general pattern of discovering misconfiguration only once a job
fails, rather than at plan/review time. A CLI runbook has no way to diff "what should exist" vs
"what actually exists," no peer review step for IAM policy changes before they take effect, and
no single source of truth once two people have run slightly different subsets of the commands
against the same account.

**Ideal, per AWS guidance:** Define infrastructure in AWS CDK or CloudFormation, so changes are
reviewable (PR diffs against the template, same as any code change), reproducible (a fresh
account/region can stand up an identical environment), and driftable-against (CloudFormation
drift detection, or a `cdk diff` before every deploy, would have caught every silent-drift bug
this guide documents encountering).
See [AWS CDK Developer Guide](https://docs.aws.amazon.com/cdk/v2/guide/home.html) and
[AWS CloudFormation User Guide](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/Welcome.html).

**Recommendation:** This is a larger effort than any other item here, so treat it as a
follow-on project, not something to do inline with the tactical fixes above. Suggested
approach:
1. Start with a CDK (TypeScript or Python) stack that models the *current* resources —
   IAM roles/policies (with the A1-A3/B/C fixes above already applied, since you're rewriting
   these anyway), the S3 bucket, VPC/security group, launch template, Batch compute
   environment/queue, ECR repo, Glue database/tables.
2. Bring the **already-running** resources under that stack's management via
   `cdk import` (CDK) or a CloudFormation import operation, rather than deleting and recreating
   them — this is the difference between a zero-downtime adoption and a disruptive one.
3. Once imported, `cdk diff`/CloudFormation change sets become the review step for every future
   infrastructure change, and `AWS_SETUP.md` becomes a "how this stack is organized and why"
   narrative doc rather than a command-by-command runbook (much shorter, and no longer needs to
   document CLI-specific gotchas like the Windows PowerShell JSON-quoting issues throughout
   §7-§9, since CDK/CloudFormation sidestep shell quoting entirely).

**Impact if changed:** **Zero to the running pipeline if done via import, as recommended.**
The risk is entirely in *how* this is executed, not *whether*: a "tear down and recreate from
CDK" approach would cause real downtime and risk the same kind of drift bugs this is meant to
fix (e.g., a recreated bucket needs the same name, which S3's global uniqueness may no longer
allow if the old one isn't deleted first). The import path avoids all of that at the cost of
more upfront CDK-authoring effort to make the template match what already exists exactly.

---

### G2. No security scanning in CI

**What we checked and why:** `.github/workflows/test.yml` runs `pytest` against
`4_generate_count_matrix/bin/`'s Python logic — useful, but scoped only to that one module's
unit tests (by the workflow's own `paths:` filter). There's no dependency-vulnerability
scanning (Dependabot alerts, or a `pip-audit`/`safety` CI step), no static analysis (CodeQL), and
no scan of the custom Docker image on build (separate from C4's ECR-side scan-on-push).

**Ideal, per AWS guidance / general practice:** Layer scanning at multiple points — dependency
scanning in CI (catches a vulnerable `awswrangler`/`boto3`/`pandas` pin before it merges), and
image scanning at both build time (CI) and registry time (C4's ECR scan-on-push), so a supply-
chain issue is caught as early as possible.

**Recommendation:** Enable GitHub's Dependabot alerts (repo Settings → Code security, free for
public repos) for `catalog/requirements.txt`, `4_generate_count_matrix/tests/requirements.txt`,
and any other Python dependency manifest. Consider adding a CodeQL workflow
(`github/codeql-action`) for the Python code. Lower priority than the AWS-account-level findings
above — this hardens the development pipeline, not the runtime AWS environment.

**Impact if changed:** None — additive CI configuration, doesn't touch runtime behavior.

---

## Suggested rollout order

Grouped by how safe each change is to apply without a dedicated test window, not by severity
alone — some High findings (like C3) are trivial to fix; some Medium findings (A2) need real
care. Updated post-live-pass: B2 is dropped (already compliant, no action needed) and H1 is
added as its own immediate phase, ahead of everything else.

**Phase 0 — immediate, do first:**
H1 (fix `aws.config`'s job-queue default — this is very likely why a default, no-flag pipeline
invocation currently fails against this account).

**Phase 1 — zero-risk, additive, do anytime:**
B1 (TLS-only bucket policy), C2 (EBS encryption), C4 (ECR scanning), C7 (terminate the orphaned
`mapped-strain-test-disposable` instance, after confirming with whoever launched it), E1
(CloudTrail), E2 (GuardDuty), E3 (AWS Config), E4 (log retention), G2 (CI scanning), C3 (fix
the documented guidance even though nothing live depends on it today).

**Phase 2 — needs a quick verification pass first (smoke test in §13, or a code review):**
C1 (codify the IMDSv2 enforcement that's already empirically true — verify the one
AWS-CLI-calling image first), F1 (SQL parameterization — code review), A1 (credential
migration — coordinate with whoever holds the current key), A3 (IAM scoping touch-ups).

**Phase 3 — needs deliberate testing against a non-production `--outdir` before wide rollout:**
A2 (S3 prefix scoping — audit every module's actual write paths first), D1 (private subnets —
`AWS_SETUP.md` §4.2 already has the steps; test image pulls and NCBI API egress through the
NAT Gateway before switching production traffic).

**Phase 4 — strategic, own project:**
G1 (IaC migration via import, not recreate) — the live pass found concrete supporting evidence
for this (orphaned launch templates, renamed-with-suffix compute environment/queue, and H1
itself), not just the theoretical case in the original write-up.

---

## Follow-up

The live verification pass above (2026-08-22) covered IAM (roles, policies, the admin user's
access key), S3 (versioning, encryption, Block Public Access, bucket policy, lifecycle rules),
EC2 (launch template contents, running instances, volume encryption, security groups),
AWS Batch (compute environment and job queue state/naming), CloudTrail, GuardDuty, AWS Config,
ECR, and Glue. Not checked in this pass, worth a follow-up if these become relevant: the exact
mechanism enforcing IMDSv2 account-wide (C1's open question), VPC/subnet/route-table detail
beyond the security group, budget/Cost Explorer configuration (§11), and Athena workgroup
settings (§14.3). Re-run against this same account periodically, or after any infrastructure
change — this pass already demonstrates real drift accumulates between what `AWS_SETUP.md`
documents and what's actually deployed.
