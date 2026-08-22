#!/usr/bin/env python
"""Screen a compendium's count matrix for likely full-gene knockouts.

Standalone QC/analysis tool -- not wired into the Nextflow pipeline as a stage.
Run manually against a completed counts.csv once a compendium run finishes.

A full gene deletion shows up as near-zero raw counts in exactly the affected
sample(s), while the same gene shows normal, robust expression across most of
the rest of the compendium. That's a different signature from "just not
expressed under this condition": a condition-specific gene stays low/absent
wherever it's biologically irrelevant, not zero specifically in one outlier
sample among many that do express it. Restricting the screen to genes that are
typically well-expressed compendium-wide (median count and active-sample
fraction both above threshold) is what tells those two cases apart.

Not exhaustive. This only catches full-gene deletions with enough
compendium-wide baseline expression to make a dropout visible in the first
place -- point mutations, small in-frame deletions, and genes that are rarely
expressed anywhere in the compendium (no baseline to compare against) are
invisible to this method. Detecting those needs variant calling against the
aligned BAMs instead, a different analysis this script doesn't attempt.
"""

from __future__ import annotations

import argparse
import sys

import pandas as pd


def find_dropouts(counts_df, min_typical_count=20, min_active_fraction=0.8, dropout_max_count=2):
    """Flag (gene, sample) pairs where a typically-expressed gene drops to
    near-zero in one sample.

    A gene is screened only if it clears both bars compendium-wide: its
    median raw count is >= min_typical_count, and it's actively expressed
    (count > dropout_max_count) in at least min_active_fraction of samples.
    Among screened genes, any sample where the count falls to
    <= dropout_max_count is flagged as a dropout event.

    Returns a DataFrame with columns: gene, sample, count, compendium_median_count.
    """
    medians = counts_df.median(axis=1)
    active_fraction = (counts_df > dropout_max_count).sum(axis=1) / counts_df.shape[1]
    typical_genes = counts_df.index[(medians >= min_typical_count) & (active_fraction >= min_active_fraction)]

    events = []
    for gene in typical_genes:
        row = counts_df.loc[gene]
        for sample in row.index[row <= dropout_max_count]:
            events.append(
                {
                    "gene": gene,
                    "sample": sample,
                    "count": row[sample],
                    "compendium_median_count": medians[gene],
                }
            )

    return pd.DataFrame(events, columns=["gene", "sample", "count", "compendium_median_count"])


def parse_args(args=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--counts", required=True, help="Path to counts.csv (genes x samples, raw counts).")
    parser.add_argument(
        "--min-typical-count",
        type=float,
        default=20,
        help="Minimum compendium-wide median raw count for a gene to be screened (default: 20).",
    )
    parser.add_argument(
        "--min-active-fraction",
        type=float,
        default=0.8,
        help="Minimum fraction of samples where a gene must be actively expressed to be screened (default: 0.8).",
    )
    parser.add_argument(
        "--dropout-max-count",
        type=float,
        default=2,
        help="Raw count at or below which a sample counts as a dropout for that gene (default: 2).",
    )
    parser.add_argument("--out", default="gene_dropout_events.csv", help="Output CSV path.")
    return parser.parse_args(args)


def main(args=None):
    args = parse_args(args)

    counts_df = pd.read_csv(args.counts, index_col=0)
    print(f"Loaded {counts_df.shape[0]} genes x {counts_df.shape[1]} samples from {args.counts}")

    medians = counts_df.median(axis=1)
    active_fraction = (counts_df > args.dropout_max_count).sum(axis=1) / counts_df.shape[1]
    n_screened = ((medians >= args.min_typical_count) & (active_fraction >= args.min_active_fraction)).sum()
    print(f"Genes screened (typically expressed compendium-wide): {n_screened}")

    events = find_dropouts(
        counts_df,
        min_typical_count=args.min_typical_count,
        min_active_fraction=args.min_active_fraction,
        dropout_max_count=args.dropout_max_count,
    )
    print(f"Dropout events found: {len(events)}")

    if events.empty:
        print("No dropout events found.")
        return

    events = events.sort_values(["sample", "gene"])
    events.to_csv(args.out, index=False)
    print(f"Wrote {args.out}")

    print("\nDropout events per sample:")
    per_sample = events.groupby("sample").size().sort_values(ascending=False)
    for sample, n in per_sample.items():
        print(f"  {sample}: {n} gene(s)")


if __name__ == "__main__":
    sys.exit(main())
