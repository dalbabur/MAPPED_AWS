#!/usr/bin/env python
"""Merge per-run Salmon quant.sf files into experiment-level expression matrices.

Reads every successfully-quantified '*_quant' directory (i.e. containing both quant.sf
and the salmon_success.flag SALMON_QUANT writes) in --search-dir, keeps only samples
whose base sample ID appears in --passed-samples-file, groups runs by experiment ID
(everything before the first underscore -- handles SRX_SRR/DRX_DRR/ERX_ERR), sums counts
for multi-run experiments and recomputes TPM from the summed counts, and writes
counts.csv/tpm.csv/log_tpm.csv to --outdir.
"""

from __future__ import annotations

import argparse
import os
import sys
from collections import defaultdict

import numpy as np
import pandas as pd


def read_passed_sample_ids(passed_samples_file):
    """Read one passed base sample ID per line; empty set if the file is missing/empty."""
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


def find_successful_quant_dirs(search_dir="."):
    """Salmon quant dirs with both quant.sf and the flag SALMON_QUANT writes on success.

    Returns (successful_dir_paths, failed_sample_names).
    """
    all_dirs = [d for d in os.listdir(search_dir) if d.endswith("_quant")]
    successful, failed = [], []
    for d in all_dirs:
        full = os.path.join(search_dir, d)
        if os.path.exists(os.path.join(full, "salmon_success.flag")) and os.path.exists(os.path.join(full, "quant.sf")):
            successful.append(full)
        else:
            failed.append(d.replace("_quant", ""))
    return successful, failed


def load_quant_sf(quant_dir):
    """Read one quant.sf; return (gene_ids, counts, tpm, lengths) as parallel lists."""
    df = pd.read_csv(os.path.join(quant_dir, "quant.sf"), sep="\t")
    return df["Name"].tolist(), df["NumReads"].tolist(), df["TPM"].tolist(), df["Length"].tolist()


def group_by_experiment(quant_dirs, passed_sample_ids):
    """Read each quant dir and group by experiment ID, skipping non-passed samples.

    Returns (gene_ids, experiment_data) where experiment_data maps experiment_id to a
    list of per-run dicts with 'counts'/'tpm'/'length' (parallel lists aligned to
    gene_ids). gene_ids is None if no quant dir was actually read.
    """
    experiment_data = defaultdict(list)
    gene_ids = None
    for quant_dir in quant_dirs:
        sample_name = os.path.basename(quant_dir.rstrip("/")).replace("_quant", "")
        if base_sample_name(sample_name) not in passed_sample_ids:
            continue
        names, counts, tpm, lengths = load_quant_sf(quant_dir)
        if gene_ids is None:
            gene_ids = names
        experiment_data[experiment_id(sample_name)].append({"counts": counts, "tpm": tpm, "length": lengths})
    return gene_ids, experiment_data


def merge_experiment_runs(gene_ids, experiment_data):
    """Sum counts across multi-run experiments and recompute TPM from summed counts.

    Single-run experiments keep their own counts/TPM unchanged (matches the original
    Salmon-reported TPM rather than re-deriving it). Returns (final_counts, final_tpm),
    each experiment_id -> a list of values aligned with gene_ids.
    """
    final_counts, final_tpm = {}, {}
    n = len(gene_ids)
    for exp_id, runs in experiment_data.items():
        if len(runs) == 1:
            final_counts[exp_id] = runs[0]["counts"]
            final_tpm[exp_id] = runs[0]["tpm"]
            continue
        summed_counts = [0] * n
        lengths = [0] * n
        for run in runs:
            for i in range(n):
                summed_counts[i] += run["counts"][i]
                lengths[i] = run["length"][i]  # length should be identical across runs
        # TPM = (counts / length) * 1e6 / sum(counts / length)
        rpk = [summed_counts[i] / lengths[i] if lengths[i] > 0 else 0 for i in range(n)]
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
    parser.add_argument("--search-dir", default=".", help="Directory to search for *_quant dirs (default: cwd).")
    parser.add_argument("--outdir", default=".", help="Directory to write tpm.csv/log_tpm.csv/counts.csv.")
    return parser.parse_args(args)


def main(args=None):
    args = parse_args(args)
    passed_sample_ids = read_passed_sample_ids(args.passed_samples_file)
    print(f"Found {len(passed_sample_ids)} passed sample IDs")

    quant_dirs, failed_samples = find_successful_quant_dirs(args.search_dir)
    print(f"Found {len(quant_dirs)} successful quantification directories")
    if failed_samples:
        print(f"Skipped {len(failed_samples)} failed samples: {', '.join(failed_samples)}")

    gene_ids, experiment_data = group_by_experiment(quant_dirs, passed_sample_ids)
    print(f"Grouped into {len(experiment_data)} experiments")

    final_counts, final_tpm = merge_experiment_runs(gene_ids or [], experiment_data)
    write_matrices(gene_ids, final_counts, final_tpm, args.outdir)

    if gene_ids and final_counts:
        print(f"Generated matrices with {len(gene_ids)} genes and {len(final_counts)} experiments")
    else:
        print("No data to process - created empty files")


if __name__ == "__main__":
    sys.exit(main())
