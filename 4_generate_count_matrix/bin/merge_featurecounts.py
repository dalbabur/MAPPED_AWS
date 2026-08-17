#!/usr/bin/env python
"""Merge per-run featureCounts outputs into experiment-level expression matrices.

Bowtie2 path's counterpart to merge_salmon_counts.py -- same experiment-grouping logic,
reading featureCounts' '<sample>_counts.txt' format instead of Salmon's quant.sf, and
computing TPM from raw counts + gene length (featureCounts reports counts and length
only, never TPM directly).
"""

from __future__ import annotations

import argparse
import glob
import os
import sys
from collections import defaultdict

import numpy as np
import pandas as pd


def read_passed_sample_ids(passed_samples_file):
    """Read one passed base sample ID per line; empty set if the file is missing/empty.

    Duplicated from merge_salmon_counts.py rather than imported: Nextflow's bin/
    auto-staging doesn't guarantee both scripts land in the same importable directory
    inside a Batch task container, and this helper is a few lines either way.
    """
    ids = set()
    if passed_samples_file and os.path.exists(passed_samples_file):
        with open(passed_samples_file) as f:
            for line in f:
                line = line.strip()
                if line:
                    ids.add(line)
    return ids


def base_sample_name(sample_name):
    """Strip TrimGalore's _val_1/_val_2 (paired) or _trimmed (single) suffix."""
    return sample_name.replace("_val_1", "").replace("_val_2", "").replace("_trimmed", "")


def experiment_id(sample_name):
    """Everything before the first underscore -- handles SRX_SRR, DRX_DRR, ERX_ERR."""
    return sample_name.split("_")[0]


def find_count_files(search_dir="."):
    """All '*_counts.txt' featureCounts output files in search_dir, sorted."""
    return sorted(glob.glob(os.path.join(search_dir, "*_counts.txt")))


def load_counts_file(count_file):
    """Read one featureCounts output file; return (gene_ids, counts, lengths).

    The file has a '# Program:featureCounts ...' comment line, then a header row
    (Geneid, Chr, Start, End, Strand, Length, <bam path>), then data. The last column's
    header is whatever BAM path was passed to featureCounts, so it's selected by
    position rather than by name.
    """
    df = pd.read_csv(count_file, sep="\t", comment="#")
    count_col = df.columns[-1]
    return df["Geneid"].tolist(), df[count_col].tolist(), df["Length"].tolist()


def group_by_experiment(count_files, passed_sample_ids):
    """Read each featureCounts file and group by experiment ID, skipping non-passed samples.

    Returns (gene_ids, gene_lengths, experiment_data) where experiment_data maps
    experiment_id to a list of per-run dicts with 'counts' (parallel to gene_ids).
    gene_ids/gene_lengths are None if no file was actually read.
    """
    experiment_data = defaultdict(list)
    gene_ids = None
    gene_lengths = None
    for count_file in count_files:
        sample_name = os.path.basename(count_file)[: -len("_counts.txt")]
        if base_sample_name(sample_name) not in passed_sample_ids:
            continue
        names, counts, lengths = load_counts_file(count_file)
        if gene_ids is None:
            gene_ids = names
            gene_lengths = lengths
        experiment_data[experiment_id(sample_name)].append({"counts": counts})
    return gene_ids, gene_lengths, experiment_data


def merge_experiment_runs(gene_ids, gene_lengths, experiment_data):
    """Sum counts across multi-run experiments, then compute TPM for every experiment
    (featureCounts never reports TPM itself, unlike Salmon). Returns
    (final_counts, final_tpm), each experiment_id -> a list of values aligned with
    gene_ids.
    """
    final_counts, final_tpm = {}, {}
    n = len(gene_ids)
    for exp_id, runs in experiment_data.items():
        if len(runs) == 1:
            summed_counts = runs[0]["counts"]
        else:
            summed_counts = [0] * n
            for run in runs:
                for i in range(n):
                    summed_counts[i] += run["counts"][i]

        rpk = [summed_counts[i] / gene_lengths[i] if gene_lengths[i] > 0 else 0 for i in range(n)]
        scale = sum(rpk) / 1e6 if sum(rpk) > 0 else 1
        final_counts[exp_id] = summed_counts
        final_tpm[exp_id] = [rpk[i] / scale if scale > 0 else 0 for i in range(n)]
    return final_counts, final_tpm


def write_matrices(gene_ids, final_counts, final_tpm, outdir="."):
    """Write counts.csv/tpm.csv/log_tpm.csv (log2(TPM+1)).

    Writes header-only files when there's no data, matching the pipeline's existing
    convention for a run with nothing to merge. Built via pandas rather than a
    per-cell Python loop -- at compendium scale (hundreds of experiments x thousands
    of genes) the loop was millions of individual f.write() calls for something
    pandas does natively in milliseconds.
    """
    os.makedirs(outdir, exist_ok=True)
    counts_path = os.path.join(outdir, "counts.csv")
    tpm_path = os.path.join(outdir, "tpm.csv")
    log_tpm_path = os.path.join(outdir, "log_tpm.csv")

    if not gene_ids or not final_counts:
        for path in (counts_path, tpm_path, log_tpm_path):
            with open(path, "w") as f:
                f.write("GeneID\n")
        return

    sorted_experiments = sorted(final_counts.keys())

    counts_df = pd.DataFrame(final_counts, index=gene_ids)[sorted_experiments]
    counts_df.index.name = "GeneID"
    counts_df.to_csv(counts_path)

    tpm_df = pd.DataFrame(final_tpm, index=gene_ids)[sorted_experiments]
    tpm_df.index.name = "GeneID"
    tpm_df.to_csv(tpm_path, float_format="%.6f")

    log_tpm_df = np.log2(tpm_df + 1)
    log_tpm_df.to_csv(log_tpm_path, float_format="%.6f")


def parse_args(args=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--passed-samples-file", required=True, help="One passed base sample ID per line.")
    parser.add_argument("--search-dir", default=".", help="Directory to search for *_counts.txt files (default: cwd).")
    parser.add_argument("--outdir", default=".", help="Directory to write tpm.csv/log_tpm.csv/counts.csv.")
    return parser.parse_args(args)


def main(args=None):
    args = parse_args(args)
    passed_sample_ids = read_passed_sample_ids(args.passed_samples_file)
    print(f"Found {len(passed_sample_ids)} passed sample IDs")

    count_files = find_count_files(args.search_dir)
    print(f"Found {len(count_files)} featureCounts output files")

    gene_ids, gene_lengths, experiment_data = group_by_experiment(count_files, passed_sample_ids)
    print(f"Grouped into {len(experiment_data)} experiments")

    final_counts, final_tpm = merge_experiment_runs(gene_ids or [], gene_lengths or [], experiment_data)
    write_matrices(gene_ids, final_counts, final_tpm, args.outdir)

    if gene_ids and final_counts:
        print(f"Generated matrices with {len(gene_ids)} genes and {len(final_counts)} experiments")
    else:
        print("No data to process - created empty files")


if __name__ == "__main__":
    sys.exit(main())
