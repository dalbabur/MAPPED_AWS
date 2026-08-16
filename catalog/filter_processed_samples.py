#!/usr/bin/env python3
"""Filter already-processed samples out of metadata/sample_id.csv (--skip-processed).

Queries the Glue Data Catalog for accessions already fully processed for this
--organism against this exact reference genome (--ref-accession-used -- the genome
actually downloaded by Stage 3, not just what --ref-accession requested, since
auto-select mode doesn't know the accession until Stage 3 runs), and rewrites
metadata/sample_id.csv to exclude them. Run by run_MAPPED.sh after Stage 1 (and, for
--skip-processed specifically, after an early Stage 3) and before Stage 2, so FASTQ
never gets downloaded for a sample that already has a complete, catalogued
quantification elsewhere in the bucket.

Matching requires organism AND ref_accession_used to agree -- the same accession
quantified against a different reference is a different result, not a repeat of the
same computation, so organism-only matching would wrongly skip work that should
actually rerun.

Always prints a final 'REMAINING_COUNT=<n>' line so run_MAPPED.sh can decide whether
there's anything left for Stage 2 to do.
"""

from __future__ import annotations

import argparse
import io
import os
import subprocess
import sys

import awswrangler as wr
import boto3
import pandas as pd

GLUE_DATABASE = "mapped_catalog"

# See register_run.py for why this is needed: awswrangler/boto3 don't auto-detect the
# region from EC2 instance metadata, so this failed with botocore.exceptions.NoRegionError
# whenever AWS_DEFAULT_REGION wasn't already set in the calling shell.
_BOTO3_SESSION = boto3.Session(region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))


def s3_cat(uri: str) -> str | None:
    result = subprocess.run(["aws", "s3", "cp", uri, "-"], capture_output=True, text=True)
    if result.returncode != 0:
        print(f"NOTE: could not read {uri} ({result.stderr.strip()})")
        return None
    return result.stdout


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--outdir", required=True)
    parser.add_argument("--organism", required=True)
    parser.add_argument("--ref-accession-used", required=True)
    args = parser.parse_args(argv)

    outdir = args.outdir.rstrip("/")
    sample_id_uri = f"{outdir}/metadata/sample_id.csv"

    text = s3_cat(sample_id_uri)
    if not text or not text.strip():
        print(f"NOTE: {sample_id_uri} not found or empty -- nothing to filter.")
        print("REMAINING_COUNT=0")
        return 0

    df = pd.read_csv(io.StringIO(text))
    if df.shape[1] == 0:
        print(f"NOTE: {sample_id_uri} has no columns -- nothing to filter.")
        print("REMAINING_COUNT=0")
        return 0
    id_col = df.columns[0]
    requested = set(df[id_col].astype(str))

    organism_sql = args.organism.replace("'", "''")
    ref_sql = args.ref_accession_used.replace("'", "''")
    query = f"""
        SELECT DISTINCT s.experiment_accession, s.outdir
        FROM {GLUE_DATABASE}.mapped_samples s
        JOIN {GLUE_DATABASE}.mapped_runs r ON s.run_id = r.run_id
        WHERE r.organism = '{organism_sql}' AND r.ref_accession_used = '{ref_sql}'
    """
    try:
        processed_df = wr.athena.read_sql_query(query, database=GLUE_DATABASE, boto3_session=_BOTO3_SESSION)
    except Exception as exc:
        print(f"WARNING: catalog query failed ({exc}) -- proceeding with the full sample list, nothing filtered.")
        print(f"REMAINING_COUNT={len(requested)}")
        return 0

    already_processed = requested & set(processed_df["experiment_accession"].astype(str)) if len(processed_df) else set()

    if not already_processed:
        print(f"No previously-processed samples found for '{args.organism}' against {args.ref_accession_used} -- nothing to skip.")
        print(f"REMAINING_COUNT={len(requested)}")
        return 0

    kept = df[~df[id_col].astype(str).isin(already_processed)]

    print(f"Skipping {len(already_processed)} of {len(requested)} requested sample(s) already processed for "
          f"'{args.organism}' against {args.ref_accession_used}:")
    locations = processed_df[processed_df["experiment_accession"].isin(already_processed)].drop_duplicates(subset=["experiment_accession"])
    for _, row in locations.iterrows():
        print(f"  {row['experiment_accession']} -> {row['outdir']}")

    buf = io.StringIO()
    kept.to_csv(buf, index=False)
    upload = subprocess.run(["aws", "s3", "cp", "-", sample_id_uri], input=buf.getvalue(), text=True)
    if upload.returncode != 0:
        print(f"WARNING: failed to write filtered {sample_id_uri} -- proceeding with the full, unfiltered sample list.")
        print(f"REMAINING_COUNT={len(requested)}")
        return 0

    print(f"REMAINING_COUNT={len(kept)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
