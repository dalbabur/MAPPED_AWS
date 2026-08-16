#!/usr/bin/env python
"""Remove samples with >50% zero-count genes from expression matrices and samplesheet.

A sample where more than half the genes have zero counts is treated as a failed/empty
library, not real (if extremely sparse) biological signal, and is dropped from
tpm.csv/log_tpm.csv/counts.csv and from the samplesheet's 'id' column together, so all
outputs stay consistent with each other.
"""

from __future__ import annotations

import argparse
import sys

import pandas as pd


def find_low_expression_samples(counts_df, threshold=0.5):
    """Sample names (column labels) where the fraction of zero-count genes exceeds
    threshold."""
    total_genes = len(counts_df)
    to_remove = []
    for sample in counts_df.columns:
        zero_count = (counts_df[sample] == 0).sum()
        zero_fraction = zero_count / total_genes if total_genes else 0
        print(f"Sample {sample}: {zero_count}/{total_genes} zeros ({zero_fraction:.2%})")
        if zero_fraction > threshold:
            to_remove.append(sample)
            print(f"  -> Will be removed (>{threshold:.0%} zeros)")
    return to_remove


def filter_matrices(tpm_df, log_tpm_df, counts_df, samples_to_remove):
    """Drop samples_to_remove as columns from all three matrices."""
    if not samples_to_remove:
        return tpm_df, log_tpm_df, counts_df
    keep = [c for c in tpm_df.columns if c not in samples_to_remove]
    return tpm_df[keep], log_tpm_df[keep], counts_df[keep]


def read_samplesheet_robust(path):
    """Read a samplesheet CSV, falling back through progressively more tolerant parsers
    for malformed input (embedded/mismatched quoting) rather than failing outright --
    this samplesheet started life as ENA/NCBI metadata, not pipeline-generated output,
    so it's the one CSV in this pipeline that isn't guaranteed well-formed.
    """
    try:
        return pd.read_csv(path)
    except pd.errors.ParserError as e:
        print(f"CSV parsing error: {e}")
        print("Attempting to fix CSV parsing issues...")
    try:
        return pd.read_csv(path, quotechar='"', skipinitialspace=True)
    except Exception:
        pass
    try:
        return pd.read_csv(path, engine="python", quotechar='"', skipinitialspace=True)
    except Exception:
        pass

    print("Reading CSV manually to handle parsing errors...")
    rows = []
    with open(path) as f:
        header = [col.strip('"') for col in f.readline().strip().split(",")]
        expected_cols = len(header)
        print(f"Expected {expected_cols} columns: {header}")
        for line_num, line in enumerate(f, start=2):
            line = line.strip()
            if not line:
                continue
            fields = _split_csv_line(line)
            if len(fields) == expected_cols:
                rows.append(fields)
            elif len(fields) > expected_cols:
                print(f"Line {line_num}: Found {len(fields)} fields, merging extras")
                rows.append(fields[: expected_cols - 1] + [",".join(fields[expected_cols - 1 :])])
            else:
                print(f"Line {line_num}: Found {len(fields)} fields, padding with empty values")
                rows.append(fields + [""] * (expected_cols - len(fields)))
    return pd.DataFrame(rows, columns=header)


def _split_csv_line(line):
    """Minimal CSV splitter tolerant of malformed/escaped quotes, used only by the
    last-resort manual-parse fallback in read_samplesheet_robust."""
    fields = []
    in_quotes = False
    current = ""
    i = 0
    while i < len(line):
        char = line[i]
        if char == '"':
            if in_quotes and i + 1 < len(line) and line[i + 1] == '"':
                current += '"'
                i += 2
                continue
            in_quotes = not in_quotes
        elif char == "," and not in_quotes:
            fields.append(current.strip('"'))
            current = ""
            i += 1
            continue
        else:
            current += char
        i += 1
    fields.append(current.strip('"'))
    return fields


def filter_samplesheet(samplesheet_df, samples_to_remove):
    """Drop rows whose 'id' column is in samples_to_remove."""
    if not samples_to_remove:
        return samplesheet_df
    return samplesheet_df[~samplesheet_df["id"].isin(samples_to_remove)]


def parse_args(args=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tpm", required=True)
    parser.add_argument("--log-tpm", required=True)
    parser.add_argument("--counts", required=True)
    parser.add_argument("--samplesheet", required=True)
    parser.add_argument("--threshold", type=float, default=0.5, help="Zero-fraction threshold (default: 0.5).")
    parser.add_argument("--outdir", default=".")
    return parser.parse_args(args)


def main(args=None):
    args = parse_args(args)

    print("Reading expression matrices...")
    tpm_df = pd.read_csv(args.tpm, index_col=0)
    log_tpm_df = pd.read_csv(args.log_tpm, index_col=0)
    counts_df = pd.read_csv(args.counts, index_col=0)
    print(f"Original matrices shape: {tpm_df.shape}")
    print(f"Sample columns: {list(tpm_df.columns)}")

    samples_to_remove = find_low_expression_samples(counts_df, args.threshold)
    print(f"\nSamples to remove ({len(samples_to_remove)}): {samples_to_remove}")

    tpm_filtered, log_tpm_filtered, counts_filtered = filter_matrices(tpm_df, log_tpm_df, counts_df, samples_to_remove)
    if samples_to_remove:
        print(f"Filtered matrices shape: {tpm_filtered.shape}")
    else:
        print("No samples need to be removed")

    tpm_filtered.to_csv(f"{args.outdir}/tpm.csv")
    log_tpm_filtered.to_csv(f"{args.outdir}/log_tpm.csv")
    counts_filtered.to_csv(f"{args.outdir}/counts.csv")

    print("Reading and filtering samplesheet...")
    samplesheet_df = read_samplesheet_robust(args.samplesheet)
    print(f"Original samplesheet shape: {samplesheet_df.shape}")

    samplesheet_filtered = filter_samplesheet(samplesheet_df, samples_to_remove)
    if samples_to_remove:
        print(f"Filtered samplesheet shape: {samplesheet_filtered.shape}")
        print(f"Removed {len(samplesheet_df) - len(samplesheet_filtered)} rows from samplesheet")

    samplesheet_filtered.to_csv(f"{args.outdir}/samplesheet.csv", index=False)

    print("\nFiltering completed successfully!")
    print(f"Final matrices have {len(tpm_filtered.columns)} samples and {len(tpm_filtered)} genes")


if __name__ == "__main__":
    sys.exit(main())
