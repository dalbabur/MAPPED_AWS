#!/usr/bin/env python3
"""Register S3 Lifecycle rules for a completed MAPPED run's outputs (pipeline Stage 6).

S3 Lifecycle rules only match by key *prefix*, and each run's --outdir bakes its name
into the top-level prefix (results-<name>/, not a shared results/<name>/ root) -- so a
single bucket-wide rule can never cover "any run's trimmed FASTQ" the way it can for
work-*/ (which does share a literal "work-" prefix across every run). This script
registers this run's own four rules (disposable seqFiles/fastq, trimmed, salmon;
Glacier-archived bowtie2 BAMs) so cost management stays automatic per run instead of
requiring a manual bucket-policy edit for every new project. See the session that added
this for the retention rationale: work-dirs and disposable results subfolders expire
after 14 days (SRA/ENA already durably host the raw FASTQ this pipeline downloads, and
everything else here is cheap to regenerate from it); BAMs move to Glacier after 30 days
since realignment, unlike requantification, is the one step actually expensive to redo.

No-ops for local (non-s3://) outdirs. Idempotent: safe to run on every pipeline
invocation, only adds rules that don't already exist.
"""

from __future__ import annotations

import argparse
import re
import sys
from urllib.parse import urlparse

import boto3
from botocore.exceptions import ClientError

WORK_DIR_RULE = {
    "ID": "expire-work-dirs",
    "Filter": {"Prefix": "work-"},
    "Status": "Enabled",
    "Expiration": {"Days": 14},
}


def parse_s3_uri(uri: str) -> tuple[str, str]:
    parsed = urlparse(uri)
    return parsed.netloc, parsed.path.lstrip("/")


def run_name_from_prefix(prefix: str) -> str:
    match = re.match(r"^results-(.+)$", prefix.rstrip("/"))
    if not match:
        raise ValueError(f"Expected outdir prefix to start with 'results-', got: {prefix!r}")
    return match.group(1)


def build_run_rules(name: str) -> list[dict]:
    base = f"results-{name}"
    return [
        {
            "ID": f"expire-fastq-{name}"[:255],
            "Filter": {"Prefix": f"{base}/seqFiles/fastq/"},
            "Status": "Enabled",
            "Expiration": {"Days": 14},
        },
        {
            "ID": f"expire-trimmed-{name}"[:255],
            "Filter": {"Prefix": f"{base}/trimmed/"},
            "Status": "Enabled",
            "Expiration": {"Days": 14},
        },
        {
            "ID": f"expire-salmon-{name}"[:255],
            "Filter": {"Prefix": f"{base}/salmon/"},
            "Status": "Enabled",
            "Expiration": {"Days": 14},
        },
        {
            "ID": f"glacier-bam-{name}"[:255],
            "Filter": {"Prefix": f"{base}/bowtie2/"},
            "Status": "Enabled",
            "Transitions": [{"Days": 30, "StorageClass": "GLACIER"}],
        },
    ]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--outdir", required=True, help="This run's --outdir (s3://... or local)")
    args = ap.parse_args()

    if not args.outdir.startswith("s3://"):
        print("Not an s3:// outdir -- lifecycle rules are S3-only, nothing to do.")
        return 0

    bucket, prefix = parse_s3_uri(args.outdir)
    name = run_name_from_prefix(prefix)

    s3 = boto3.client("s3")

    try:
        existing = s3.get_bucket_lifecycle_configuration(Bucket=bucket)["Rules"]
    except ClientError as e:
        if e.response["Error"]["Code"] == "NoSuchLifecycleConfiguration":
            existing = []
        else:
            raise

    existing_ids = {r["ID"] for r in existing}
    wanted = build_run_rules(name)
    if "expire-work-dirs" not in existing_ids:
        wanted = [WORK_DIR_RULE] + wanted

    to_add = [r for r in wanted if r["ID"] not in existing_ids]
    if not to_add:
        print(f"Lifecycle rules for run '{name}' already registered -- nothing to do.")
        return 0

    merged = existing + to_add
    s3.put_bucket_lifecycle_configuration(Bucket=bucket, LifecycleConfiguration={"Rules": merged})
    print(f"Registered {len(to_add)} lifecycle rule(s) for run '{name}': {[r['ID'] for r in to_add]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
