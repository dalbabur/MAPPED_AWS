# aws-cloud-architect memory — MAPPED_AWS

Seeded 2026-08-22 from the live-verification pass in `AWS_SECURITY_AUDIT.md` (repo root) — check
there for full detail and citations; this is the condensed, durable-fact version for quick
reference before acting.

## Account

- Account ID: `347076821446`. Region: `us-east-1` (hardcoded throughout — co-located with SRA
  Open Data buckets).
- **The credential backing AWS MCP access to this account was, as of 2026-08-22, the account
  root user** (`arn:aws:iam::347076821446:root`), not an IAM identity. Check
  `aws sts get-caller-identity` at the start of any session — if still root, treat A0 in the
  audit as still open and be extra careful; if it's been swapped to an IAM identity, update this
  note with what it is.
- `mapped-admin` IAM user exists with `AdministratorAccess` attached directly and an active
  long-lived access key (created 2026-08-15). Used for privileged provisioning per
  `AWS_SETUP.md` §2. Check whether this has been rotated/scoped down (audit finding A1) before
  assuming it's still in this state.

## Known live/documented drift (verify current state before relying on any of this)

- **Batch job queue is named `mapped-spot-queue4`**, compute environment `mapped-spot-ce4` — not
  the `mapped-spot-queue`/`mapped-spot-ce` names `AWS_SETUP.md` §8 and `aws.config` document.
  `aws.config` line ~72 defaults to `mapped-spot-queue` (doesn't exist) unless
  `--aws_batch_queue` is passed explicitly. This is audit finding H1 — check whether it's been
  fixed; if `aws.config` still says `mapped-spot-queue` without the `4`, it hasn't.
- Free Tier instance-type restriction on this account: only `c7i-flex.large`/`m7i-flex.large`
  (2 vCPU/8 GiB) available for Batch (`t3.*` excluded — AWS Batch doesn't support the T family
  regardless of Free Tier eligibility). `aws.config`'s per-process cpu/memory directives are
  capped at 2 vCPU accordingly. Re-check
  `aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true` if this
  account's Free Tier status might have changed.
- Launch template `mapped-batch-lt` had, as of 2026-08-22, no `MetadataOptions` block (root EBS
  volume also not marked `Encrypted: true`), yet every live-checked running instance showed
  `HttpTokens: required`/`HttpPutResponseHopLimit: 2` anyway — mechanism not fully identified.
  Don't assume this protection survives a future launch-template recreation unless it's been
  made explicit in the template itself (audit finding C1).
- S3 bucket `mapped-pipeline-347076821446`: versioning enabled, SSE-S3/AES256, **Block Public
  Access fully enabled** (already compliant, don't re-flag). No bucket policy (no TLS
  enforcement). Both `MappedBatchJobRole` and `MappedHeadNodeRole` grant bucket-wide
  `DeleteObject`, not prefix-scoped. The historical bucket-name-placeholder bug from
  `AWS_SETUP.md` §5 is *not* currently present.
- No CloudTrail trail, no GuardDuty detector, no AWS Config recorder existed as of 2026-08-22.
  ECR repo `mapped/sra-fastq-awsodp` has scan-on-push disabled and mutable tags.
- Undocumented EC2 instance `mapped-strain-test-disposable` (t3.small, public IP) found running
  with no ties to the managed compute environment or head node — likely a leftover debug
  instance. Check if it's still running; if so and unclaimed, it's a cost leak.

## Preferences observed

- Four-part finding structure for anything audit/remediation-shaped: what/why, ideal + AWS doc
  citation, recommendation, impact/blast-radius.
- Full audit report: `AWS_SECURITY_AUDIT.md` in the repo root.

## Remediation log

Dated entries, newest last.

- **2026-08-22** — Memory seeded from the audit; no remediation performed yet. The audit's own
  "Suggested rollout order" is the intended sequence: Phase 0 (H1, the job-queue name fix)
  first, then Phase 1's zero-risk additive items, then Phase 2/3/4 in order.
