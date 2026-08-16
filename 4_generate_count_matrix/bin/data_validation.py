#!/usr/bin/env python
"""Validate and reconcile the samplesheet against the expression matrices.

Ensures the samplesheet's 'sample' column matches the expression matrices' columns
exactly (merging duplicate rows, i.e. multiple SRA runs for the same experiment, along
the way), and strips a literal 'gene-' ID prefix from matrix row indices if present.
This is the pipeline's final consistency gate: fails loudly (unlike the rest of this
module, which mostly logs and continues) since a mismatch here means the published
expression matrices and samplesheet would silently disagree about which samples exist.
"""

from __future__ import annotations

import argparse
import shutil
import sys

import pandas as pd

# Columns concatenated with ';' when merging duplicate rows (multiple SRA runs for the
# same experiment); everything else takes the first non-null value across the group.
CONCAT_COLUMNS = [
    "run_accession", "id", "fastq_1", "fastq_2", "fastq_md5",
    "fastq_bytes", "fastq_ftp", "fastq_galaxy", "fastq_aspera",
    "run_alias", "base_count", "read_count",
]

MATRIX_FILENAMES = ("counts.csv", "tpm.csv", "log_tpm.csv", "log_tpm_norm.csv")


def merge_duplicate_download_rows(download_df):
    """Merge samplesheet_download.csv rows sharing the same experiment ID (id split on
    the first '_'). The merged row's 'id' becomes the bare experiment ID itself (not a
    semicolon join, even though 'id' is in CONCAT_COLUMNS) -- unlike
    merge_duplicate_samplesheet_rows, which has no such override, since here the
    experiment ID is being *derived*, not merged from already-experiment-level values.
    No-ops (returns the input unchanged) if there's no 'id' column to group by.
    """
    if "id" not in download_df.columns:
        print("ERROR: 'id' column not found in samplesheet_download.csv")
        return download_df

    df = download_df.copy()
    df["experiment_id"] = df["id"].str.split("_").str[0]
    print(f"Found {df['experiment_id'].nunique()} unique experiments from {len(df)} rows")

    merged_rows = []
    for exp_id, group in df.groupby("experiment_id"):
        if len(group) == 1:
            row = group.iloc[0].to_dict()
            row["id"] = exp_id
            merged_rows.append(row)
            continue
        merged_row = {"id": exp_id, "experiment_id": exp_id}
        for col in df.columns:
            if col in ("id", "experiment_id"):
                continue
            if col in CONCAT_COLUMNS:
                values = group[col].dropna().astype(str).tolist()
                merged_row[col] = ";".join(values) if values else ""
            else:
                non_null = group[col].dropna()
                merged_row[col] = non_null.iloc[0] if len(non_null) else ""
        merged_rows.append(merged_row)

    merged_df = pd.DataFrame(merged_rows)
    return merged_df.drop(columns=["experiment_id"], errors="ignore")


def find_sample_id_column(samplesheet_df):
    """The samplesheet column identifying each sample -- 'sample' if present, else the
    first match among common alternates. None if none of them are present.
    """
    if "sample" in samplesheet_df.columns:
        return "sample"
    for col in ("Sample", "experiment_accession", "sample_id", "Sample_ID", "id"):
        if col in samplesheet_df.columns:
            return col
    return None


def merge_duplicate_samplesheet_rows(samplesheet_df, sample_col):
    """Merge samplesheet rows sharing the same value in sample_col (multiple SRA runs
    for the same experiment). Unlike merge_duplicate_download_rows, sample_col's own
    value is never overridden -- duplicates are rows that already share it verbatim,
    not something being derived.
    """
    merged_rows = []
    for _sample_id, group in samplesheet_df.groupby(sample_col):
        if len(group) == 1:
            merged_rows.append(group.iloc[0].to_dict())
            continue
        merged_row = {}
        for col in samplesheet_df.columns:
            if col in CONCAT_COLUMNS:
                values = group[col].dropna().astype(str).tolist()
                merged_row[col] = ";".join(values) if values else ""
            else:
                non_null = group[col].dropna()
                merged_row[col] = non_null.iloc[0] if len(non_null) else ""
        merged_rows.append(merged_row)
    return pd.DataFrame(merged_rows)


def reconcile_samplesheet_with_matrices(samplesheet_df, sample_col, expression_samples):
    """Keep only samplesheet rows present in expression_samples, rename sample_col to
    'sample', and move it to the first column. expression_samples is the exact set of
    columns already confirmed consistent across all four matrices.
    """
    filtered = samplesheet_df[samplesheet_df[sample_col].astype(str).isin(expression_samples)]
    if sample_col != "sample":
        filtered = filtered.rename(columns={sample_col: "sample"})
    cols = filtered.columns.tolist()
    if "sample" in cols:
        cols.remove("sample")
        cols = ["sample"] + cols
    return filtered[cols]


def strip_gene_prefix(df, prefix="gene-"):
    """Strip a literal prefix (e.g. 'gene-') from every row index value, if the first
    entry has it. Assumes all-or-nothing: a GFF either consistently uses the prefix in
    its ID attribute or it doesn't. Empty matrices (0 rows) pass through unchanged --
    legitimate (e.g. log_tpm_norm.csv's row-mean centering trivially zeroes and drops
    every gene when there's exactly one sample), not an error.
    """
    if len(df) == 0:
        return df, False
    if not str(df.index[0]).startswith(prefix):
        return df, False
    df = df.copy()
    df.index = df.index.str.replace(f"^{prefix}", "", regex=True)
    return df, True


def validate_matrix_columns_consistent(matrix_columns):
    """matrix_columns: dict of matrix name -> list of column names. Raises ValueError
    naming the mismatch if any two matrices disagree; otherwise returns the shared
    column list.
    """
    all_columns = list(matrix_columns.values())
    reference = all_columns[0]
    if not all(cols == reference for cols in all_columns[1:]):
        raise ValueError(f"Expression matrices have inconsistent columns: {matrix_columns}")
    return reference


def parse_args(args=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samplesheet", required=True)
    parser.add_argument("--tpm", required=True)
    parser.add_argument("--log-tpm", required=True)
    parser.add_argument("--counts", required=True)
    parser.add_argument("--log-tpm-norm", required=True)
    parser.add_argument("--samplesheet-download", default=None, help="Optional; skipped if not provided or missing.")
    parser.add_argument("--outdir", default=".")
    return parser.parse_args(args)


def main(args=None):
    args = parse_args(args)

    print("=== DATA_VALIDATION ===")
    print("Ensuring samplesheet 'sample' column matches expression matrix columns exactly...")
    print("Also checking and fixing gene ID prefixes...")

    if args.samplesheet_download:
        print("\n=== PROCESSING SAMPLESHEET_DOWNLOAD.CSV ===")
        try:
            download_df = pd.read_csv(args.samplesheet_download)
            print(f"Original samplesheet_download.csv: {len(download_df)} rows")
            merged_download_df = merge_duplicate_download_rows(download_df)
            print(f"After merging by experiment: {len(merged_download_df)} rows")
            merged_download_df.to_csv(f"{args.outdir}/samplesheet_download.csv", index=False)
            print("Updated samplesheet_download.csv with merged experiments")
        except Exception as e:
            print(f"ERROR processing samplesheet_download.csv: {e}")
            shutil.copy(args.samplesheet_download, f"{args.outdir}/samplesheet_download.csv")

    print("\nReading expression matrices...")
    matrix_files = {
        "counts.csv": args.counts,
        "tpm.csv": args.tpm,
        "log_tpm.csv": args.log_tpm,
        "log_tpm_norm.csv": args.log_tpm_norm,
    }
    matrix_dfs = {}
    matrix_columns = {}
    for name, path in matrix_files.items():
        df = pd.read_csv(path, index_col=0)
        matrix_dfs[name] = df
        matrix_columns[name] = list(df.columns)
        print(f"  {name}: {len(df.columns)} samples")

    reference_cols = validate_matrix_columns_consistent(matrix_columns)
    expression_samples = set(reference_cols)
    print(f"\nExpression matrices: {len(expression_samples)} samples found")

    print("\nReading samplesheet...")
    samplesheet_df = pd.read_csv(args.samplesheet)
    print(f"Original samplesheet: {len(samplesheet_df)} rows")

    sample_col = find_sample_id_column(samplesheet_df)
    if sample_col is None:
        print("ERROR: Could not identify sample ID column in samplesheet")
        print(f"Available columns: {list(samplesheet_df.columns)}")
        return 1
    print(f"Using column '{sample_col}' as sample ID")

    print("\nChecking for duplicate samples...")
    duplicates = samplesheet_df[samplesheet_df.duplicated(subset=[sample_col], keep=False)]
    if len(duplicates) > 0:
        print(f"Found {samplesheet_df[sample_col].nunique()} unique samples from {len(samplesheet_df)} rows")
        samplesheet_df = merge_duplicate_samplesheet_rows(samplesheet_df, sample_col)
        print(f"After merging: {len(samplesheet_df)} rows")

    samplesheet_samples = set(samplesheet_df[sample_col].astype(str).unique())
    samples_to_keep = samplesheet_samples & expression_samples
    samples_to_remove = samplesheet_samples - expression_samples
    missing_samples = expression_samples - samplesheet_samples
    print("\nAnalysis:")
    print(f"  - Samples in both: {len(samples_to_keep)}")
    print(f"  - Samples to remove from samplesheet: {len(samples_to_remove)}")
    print(f"  - Samples missing from samplesheet: {len(missing_samples)}")

    filtered_samplesheet = reconcile_samplesheet_with_matrices(samplesheet_df, sample_col, expression_samples)
    if sample_col != "sample":
        print(f"\nRenamed column '{sample_col}' to 'sample'")
    filtered_samplesheet.to_csv(f"{args.outdir}/samplesheet.csv", index=False)
    print(f"\nUpdated samplesheet: {len(samplesheet_df)} → {len(filtered_samplesheet)} rows")

    print("\n=== PROCESSING GENE IDs ===")
    for name, df in matrix_dfs.items():
        stripped_df, changed = strip_gene_prefix(df)
        if len(df) == 0:
            print(f"{name}: Empty matrix (0 genes), skipping gene ID prefix check")
        elif changed:
            print(f"{name}: Found 'gene-' prefix in gene IDs, removing...")
        else:
            print(f"{name}: No 'gene-' prefix found in gene IDs")
        stripped_df.to_csv(f"{args.outdir}/{name}")

    print("\n=== FINAL VERIFICATION ===")
    final_samplesheet_samples = set(filtered_samplesheet["sample"].astype(str).unique())
    matrix_samples = set(reference_cols)
    if final_samplesheet_samples == matrix_samples:
        print("SUCCESS: Samplesheet 'sample' column now matches expression matrix columns exactly!")
        print(f"   Both contain {len(matrix_samples)} samples")
        return 0

    in_samplesheet_not_matrix = final_samplesheet_samples - matrix_samples
    in_matrix_not_samplesheet = matrix_samples - final_samplesheet_samples
    if in_samplesheet_not_matrix:
        print(f"ERROR: {len(in_samplesheet_not_matrix)} samples in samplesheet but not in matrices")
    if in_matrix_not_samplesheet:
        print(f"ERROR: {len(in_matrix_not_samplesheet)} samples in matrices but not in samplesheet")
        if len(in_matrix_not_samplesheet) <= 10:
            print(f"   Missing samples: {sorted(in_matrix_not_samplesheet)}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
