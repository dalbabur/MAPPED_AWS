#!/usr/bin/env python
"""Row-center a log-TPM matrix by subtracting each gene's row-wise mean.

Puts every gene's expression on the same relative scale (deviation from its own mean
across samples) rather than absolute log-TPM, which is what downstream ICA/iModulon-style
analysis expects. Genes whose centered value is exactly zero in every sample (no
variance to explain -- notably every gene when there's only one sample) are dropped.
"""

from __future__ import annotations

import argparse
import sys

import pandas as pd


def normalize(df):
    """Subtract the row-wise mean of all numeric columns (every column except the
    first, GeneID) from each value in that row, then drop rows that become entirely
    zero. df's first column is carried through unchanged as the row identifier.
    """
    gene_col = df.iloc[:, 0]
    numeric_data = df.iloc[:, 1:]

    row_mean = numeric_data.mean(axis=1)
    adjusted = numeric_data.sub(row_mean, axis=0)

    keep_mask = ~adjusted.eq(0).all(axis=1)
    adjusted = adjusted[keep_mask]
    gene_col = gene_col[keep_mask]

    return pd.concat([gene_col, adjusted], axis=1)


def parse_args(args=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log-tpm", required=True, help="Input log_tpm.csv path.")
    parser.add_argument("--output", default="log_tpm_norm.csv")
    return parser.parse_args(args)


def main(args=None):
    args = parse_args(args)
    df = pd.read_csv(args.log_tpm)
    normalize(df).to_csv(args.output, index=False)


if __name__ == "__main__":
    sys.exit(main())
