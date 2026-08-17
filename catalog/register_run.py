#!/usr/bin/env python3
"""Register a completed MAPPED run in the Glue Data Catalog (pipeline Stage 5).

Reads this run's samplesheet_download.csv/samplesheet.csv from its --outdir, writes
normalized Parquet rows describing the run and its samples to
s3://<bucket>/catalog/{runs,samples}/run_id=<run_id>/, and registers the Glue partition
via awswrangler -- no crawler, immediately queryable from Athena. No-ops for local
(non-s3://) outdirs, since the catalog is S3/Glue-only. The Glue database and both
tables must already exist (see AWS_SETUP.md); this script only ever reads/writes
partitions, never creates or alters table/database definitions.
"""

from __future__ import annotations

import argparse
import io
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

import awswrangler as wr
import boto3
import pandas as pd

GLUE_DATABASE = "mapped_catalog"
RUNS_TABLE = "mapped_runs"
SAMPLES_TABLE = "mapped_samples"

# awswrangler/boto3 don't auto-detect the region from EC2 instance metadata the way the
# `aws` CLI does -- this script previously relied on AWS_DEFAULT_REGION already being set
# in the calling shell, which run_MAPPED.sh's Step 5 never did, so every Glue write here
# failed with botocore.exceptions.NoRegionError regardless of catalog table state.
# Explicit fallback matches aws.config's own hardcoded region.
_BOTO3_SESSION = boto3.Session(region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))

# Real ENA `read_run` fields carried into samplesheet.csv by
# 2_download_fastq/bin/sra_ids_to_runinfo.py's ENA_METADATA_FIELDS -- not the capitalized
# NCBI `efetch runinfo` fields, which only ever exist in Module 1's intermediate
# metadata.tsv and never reach samplesheet.csv. 'sample' and 'id' are handled separately
# below (renamed to experiment_accession/sra_run_ids); the raw ENA 'experiment_accession'
# field is intentionally dropped as redundant with the guaranteed-correct 'sample' column.
#
# Typed string throughout, including base_count/read_count: DATA_VALIDATION's
# concat_columns (4_generate_count_matrix/main.nf) semicolon-joins several of these
# (e.g. base_count: "1234;5678") when merging duplicate SRA runs into one experiment, so
# none of them are safe as numeric Glue types.
SAMPLE_ENA_COLUMNS = [
    "run_accession", "sample_accession", "secondary_sample_accession",
    "study_accession", "secondary_study_accession", "submission_accession",
    "run_alias", "experiment_alias", "sample_alias", "study_alias",
    "library_layout", "library_selection", "library_source",
    "library_strategy", "library_name", "instrument_model",
    "instrument_platform", "base_count", "read_count", "tax_id",
    "scientific_name", "sample_title", "experiment_title", "study_title",
    "sample_description", "fastq_1", "fastq_2", "fastq_md5", "fastq_bytes",
    "fastq_ftp", "fastq_galaxy", "fastq_aspera",
]

SAMPLE_COLUMNS = ["experiment_accession", "sra_run_ids", "organism", "outdir", "quantifier", "bam_path"] + SAMPLE_ENA_COLUMNS

_RUN_ID_UNSAFE = re.compile(r"[^A-Za-z0-9._-]")
_REF_ACCESSION = re.compile(r"GC[AF]_[0-9]+\.[0-9]+")


def derive_run_id(outdir: str) -> str:
    """Derive a deterministic, human-readable run_id from an s3:// --outdir.

    e.g. s3://my-mapped-bucket/results/ecoli-k12 -> my-mapped-bucket__results__ecoli-k12
    Re-registering the same --outdir (e.g. after a -resume re-run) reuses the same run_id,
    which combined with mode="overwrite_partitions" replaces that run's catalog rows
    rather than duplicating them.
    """
    stripped = outdir.removeprefix("s3://").strip("/")
    return _RUN_ID_UNSAFE.sub("-", stripped.replace("/", "__"))


def s3_cat(uri: str) -> str | None:
    """Return an S3 object's contents as text, or None if it can't be read."""
    result = subprocess.run(["aws", "s3", "cp", uri, "-"], capture_output=True, text=True)
    if result.returncode != 0:
        print(f"NOTE: could not read {uri} ({result.stderr.strip()})")
        return None
    return result.stdout


def read_csv_from_s3(uri: str) -> pd.DataFrame | None:
    text = s3_cat(uri)
    if not text or not text.strip():
        return None
    return pd.read_csv(io.StringIO(text))


def resolve_ref_accession_used(outdir: str) -> str | None:
    """Best-effort: the GCA_/GCF_ accession actually downloaded to seqFiles/ref_genome/.

    Useful when --ref-accession was left blank (auto-select mode) -- resolves what genome
    the pipeline actually picked, not just what the user requested.
    """
    result = subprocess.run(
        ["aws", "s3", "ls", f"{outdir}/seqFiles/ref_genome/"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        return None
    matches = sorted(set(_REF_ACCESSION.findall(result.stdout)))
    if not matches:
        return None
    if len(matches) > 1:
        print(f"WARNING: multiple reference accessions found under {outdir}/seqFiles/ref_genome/: {matches}; using {matches[0]}")
    return matches[0]


def resolve_annotation_version(outdir: str, ref_accession_used: str | None) -> str | None:
    """Best-effort: the NCBI annotation release actually used for ref_accession_used
    (e.g. 'GCF_000007565.2-RS_2025_02_17'), read from datasets_summary.json.

    Distinct from the assembly accession itself -- NCBI can re-run its PGAP annotation
    pipeline on the same assembly accession without bumping that accession's version, so
    this is what actually changes when gene annotations get updated later. None if the
    summary is missing/unreadable, has no record matching ref_accession_used, or the
    assembly has no RefSeq annotation at all (e.g. a GenBank-only GCA_ accession).
    """
    if not ref_accession_used:
        return None
    text = s3_cat(f"{outdir}/seqFiles/ref_genome/datasets_summary.json")
    if not text:
        return None
    # datasets_summary.json is JSON-lines (one record per candidate genome for
    # auto-select mode, one line for accession mode) -- match the specific record for
    # the accession actually downloaded rather than assuming line 1.
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if record.get("accession") != ref_accession_used:
            continue
        annotation_info = record.get("annotation_info") or {}
        return annotation_info.get("name") or annotation_info.get("release_date")
    return None


def resolve_qc_metrics(outdir: str) -> dict:
    """Best-effort: run-wide mapping-rate/assignment-rate/rRNA-tRNA-fraction summary
    from qc_metrics.json (4_generate_count_matrix/bin/compute_qc_metrics.py).

    Only ever produced on the Bowtie2 quantifier path (see that script's docstring for
    why); an empty dict here for a Salmon run or an older run predating this metric is
    expected, not an error -- every value ends up null in the catalog row either way.
    """
    text = s3_cat(f"{outdir}/qc_metrics.json")
    if not text:
        return {}
    try:
        return json.loads(text).get("summary") or {}
    except json.JSONDecodeError:
        return {}


def build_runs_row(
    args: argparse.Namespace,
    run_id: str,
    download_df: pd.DataFrame | None,
    samplesheet_df: pd.DataFrame | None,
    ref_accession_used: str | None,
    annotation_version: str | None,
    qc_metrics: dict,
) -> pd.DataFrame:
    row = {
        "run_id": run_id,
        "outdir": args.outdir,
        "workdir": args.workdir,
        "organism": args.organism,
        "strain": args.strain,
        "bioproject": args.bioproject,
        "sra_accessions": args.sra_accessions,
        "ref_accession": args.ref_accession,
        "ref_accession_used": ref_accession_used,
        "annotation_version": annotation_version,
        "library_layout": args.library_layout,
        "quantifier": args.quantifier,
        "cpu": int(args.cpu) if args.cpu else None,
        "run_timestamp": datetime.now(timezone.utc),
        "n_samples_downloaded": len(download_df) if download_df is not None else None,
        "n_samples_passed_qc": len(samplesheet_df) if samplesheet_df is not None else 0,
        "aws_batch_queue": args.aws_batch_queue,
        "mean_mapping_rate_pct": qc_metrics.get("mean_mapping_rate_pct"),
        "mean_assignment_rate_pct": qc_metrics.get("mean_assignment_rate_pct"),
        "mean_rrna_fraction_pct": qc_metrics.get("mean_rrna_fraction_pct"),
        "mean_trna_fraction_pct": qc_metrics.get("mean_trna_fraction_pct"),
    }
    df = pd.DataFrame([row])
    string_cols = [
        "run_id", "outdir", "workdir", "organism", "strain", "bioproject",
        "sra_accessions", "ref_accession", "ref_accession_used", "annotation_version",
        "library_layout", "quantifier", "aws_batch_queue",
    ]
    for col in string_cols:
        df[col] = df[col].astype("string")
    for col in ["cpu", "n_samples_downloaded", "n_samples_passed_qc"]:
        df[col] = df[col].astype("Int64")
    for col in ["mean_mapping_rate_pct", "mean_assignment_rate_pct", "mean_rrna_fraction_pct", "mean_trna_fraction_pct"]:
        df[col] = df[col].astype("float64")
    df["run_timestamp"] = pd.to_datetime(df["run_timestamp"])
    return df


def build_bam_paths(id_col: pd.Series, outdir: str, quantifier: str | None) -> pd.Series:
    """Semicolon-joined s3:// paths to each experiment's underlying run-level BAM(s),
    positionally parallel to sra_run_ids -- same run-tag order, same ';' join -- since
    BOWTIE2_ALIGN/SAM_SORT_INDEX (4_generate_count_matrix/main.nf) tag each output
    '<run_tag>.sorted.bam' with the same per-run id that ends up (semicolon-joined for
    multi-run experiments) in sra_run_ids.

    Best-effort like resolve_ref_accession_used/the ENA fastq_* columns already in this
    table -- constructed from the known publishDir naming convention, not verified to
    exist (a run whose BOWTIE2_ALIGN/FEATURECOUNTS failed for one run of a multi-run
    experiment would still get a path here that 404s). All-NA when --quantifier wasn't
    'bowtie2', since only that path publishes BAMs at all.
    """
    if quantifier != "bowtie2":
        return pd.Series(pd.NA, index=id_col.index, dtype="object")

    def paths_for(run_ids):
        if pd.isna(run_ids):
            return pd.NA
        return ";".join(f"{outdir}/bowtie2/{r}.sorted.bam" for r in str(run_ids).split(";"))

    return id_col.apply(paths_for)


def build_samples_df(
    samplesheet_df: pd.DataFrame | None,
    run_id: str,
    organism: str,
    outdir: str,
    quantifier: str | None,
) -> pd.DataFrame | None:
    """One row per samplesheet.csv row -- the QC-passed set that matches the expression
    matrix columns exactly (DATA_VALIDATION's own hard-guaranteed invariant). Returns
    None (no table write) when there's nothing to register, so a run that legitimately
    filtered out every sample doesn't produce an empty/junk partition.
    """
    if samplesheet_df is None or len(samplesheet_df) == 0:
        return None
    if "sample" not in samplesheet_df.columns:
        print("WARNING: samplesheet.csv has no 'sample' column -- skipping mapped_samples registration for this run")
        return None

    df = pd.DataFrame(index=samplesheet_df.index)
    df["experiment_accession"] = samplesheet_df["sample"]
    id_col = samplesheet_df["id"] if "id" in samplesheet_df.columns else pd.Series(pd.NA, index=samplesheet_df.index)
    df["sra_run_ids"] = id_col
    df["organism"] = organism
    df["outdir"] = outdir
    df["quantifier"] = quantifier
    df["bam_path"] = build_bam_paths(id_col, outdir, quantifier)
    for col in SAMPLE_ENA_COLUMNS:
        df[col] = samplesheet_df[col] if col in samplesheet_df.columns else pd.NA
    df["run_id"] = run_id

    for col in ["run_id"] + SAMPLE_COLUMNS:
        df[col] = df[col].astype("string")
    return df


def parse_args(argv=None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--outdir", required=True)
    parser.add_argument("--workdir", default=None)
    parser.add_argument("--organism", required=True)
    parser.add_argument("--library-layout", required=True)
    parser.add_argument("--strain", default=None)
    parser.add_argument("--bioproject", default=None)
    parser.add_argument("--sra-accessions", default=None)
    parser.add_argument("--ref-accession", default=None)
    parser.add_argument("--quantifier", default=None)
    parser.add_argument("--cpu", default=None)
    parser.add_argument("--aws-batch-queue", default=None)
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)

    if not args.outdir.startswith("s3://"):
        print(f"Catalog registration skipped: --outdir '{args.outdir}' is not an s3:// path (local runs aren't cataloged).")
        return 0

    outdir = args.outdir.rstrip("/")
    run_id = derive_run_id(outdir)
    bucket = outdir.removeprefix("s3://").split("/")[0]
    catalog_root = f"s3://{bucket}/catalog"

    download_df = read_csv_from_s3(f"{outdir}/samplesheet/samplesheet_download.csv")
    samplesheet_df = read_csv_from_s3(f"{outdir}/samplesheet/samplesheet.csv")
    ref_accession_used = resolve_ref_accession_used(outdir)
    annotation_version = resolve_annotation_version(outdir, ref_accession_used)
    qc_metrics = resolve_qc_metrics(outdir)

    runs_row = build_runs_row(args, run_id, download_df, samplesheet_df, ref_accession_used, annotation_version, qc_metrics)
    samples_df = build_samples_df(samplesheet_df, run_id, args.organism, outdir, args.quantifier)

    wr.s3.to_parquet(
        df=runs_row,
        path=f"{catalog_root}/runs/",
        dataset=True,
        database=GLUE_DATABASE,
        table=RUNS_TABLE,
        partition_cols=["run_id"],
        mode="overwrite_partitions",
        schema_evolution=False,
        boto3_session=_BOTO3_SESSION,
        dtype={
            "outdir": "string", "workdir": "string", "organism": "string",
            "strain": "string", "bioproject": "string", "sra_accessions": "string",
            "ref_accession": "string", "ref_accession_used": "string",
            "annotation_version": "string",
            "library_layout": "string", "quantifier": "string", "cpu": "int",
            "run_timestamp": "timestamp", "n_samples_downloaded": "int",
            "n_samples_passed_qc": "int", "aws_batch_queue": "string",
            "mean_mapping_rate_pct": "double", "mean_assignment_rate_pct": "double",
            "mean_rrna_fraction_pct": "double", "mean_trna_fraction_pct": "double",
        },
    )
    n_passed = runs_row["n_samples_passed_qc"].iloc[0]
    n_downloaded = runs_row["n_samples_downloaded"].iloc[0]
    print(f"Registered run '{run_id}' in {GLUE_DATABASE}.{RUNS_TABLE} ({n_passed} of {n_downloaded} samples passed QC)")

    if samples_df is not None:
        wr.s3.to_parquet(
            df=samples_df,
            path=f"{catalog_root}/samples/",
            dataset=True,
            database=GLUE_DATABASE,
            table=SAMPLES_TABLE,
            partition_cols=["run_id"],
            mode="overwrite_partitions",
            schema_evolution=False,
            boto3_session=_BOTO3_SESSION,
            dtype={col: "string" for col in SAMPLE_COLUMNS},
        )
        print(f"Registered {len(samples_df)} sample(s) in {GLUE_DATABASE}.{SAMPLES_TABLE}")
    else:
        print(f"No samples to register -- {SAMPLES_TABLE} left untouched for run_id '{run_id}'")

    return 0


if __name__ == "__main__":
    sys.exit(main())
