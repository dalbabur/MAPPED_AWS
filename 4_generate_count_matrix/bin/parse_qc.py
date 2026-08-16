#!/usr/bin/env python
"""Parse MultiQC's JSON to find which experiments pass FastQC's key quality metrics.

An experiment passes only if *every* one of its runs passes all three target metrics
(per_base_sequence_quality, per_sequence_quality_scores, per_base_n_content) -- one bad
run fails the whole experiment, since downstream steps merge runs together per
experiment and a bad run would otherwise silently contaminate the merged result.
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
import traceback

TARGET_METRICS = ("per_base_sequence_quality", "per_sequence_quality_scores", "per_base_n_content")


def base_sample_name(sample_name):
    """Strip TrimGalore's _val_1/_val_2 (paired) or _trimmed (single) suffix."""
    return sample_name.replace("_val_1", "").replace("_val_2", "").replace("_trimmed", "")


def experiment_id(sample_name):
    """Everything before the first underscore -- handles SRX_SRR, DRX_DRR, ERX_ERR."""
    return sample_name.split("_")[0]


def extract_fastqc_data(multiqc_data):
    """The FastQC raw-data block MultiQC embeds, or None if it's not present."""
    return multiqc_data.get("report_saved_raw_data", {}).get("multiqc_fastqc")


def evaluate_samples(fastqc_data):
    """Evaluate every sample against TARGET_METRICS.

    Returns (qc_results, experiment_status, experiment_samples):
      qc_results: list of per-sample dicts (sample, each target metric, overall_status)
      experiment_status: experiment_id -> bool (True iff every one of its samples passed)
      experiment_samples: experiment_id -> set of base sample names belonging to it
    """
    experiment_status = {}
    experiment_samples = {}
    qc_results = []

    for sample_name, sample_data in fastqc_data.items():
        exp_id = experiment_id(sample_name)
        base_name = base_sample_name(sample_name)

        sample_qc = {"sample": sample_name}
        ok = True
        for metric in TARGET_METRICS:
            status = sample_data.get(metric, "unknown")
            sample_qc[metric] = status
            if status != "pass":
                ok = False
        sample_qc["overall_status"] = "PASS" if ok else "FAIL"
        qc_results.append(sample_qc)

        experiment_status.setdefault(exp_id, True)
        experiment_samples.setdefault(exp_id, set()).add(base_name)
        if not ok:
            experiment_status[exp_id] = False

    return qc_results, experiment_status, experiment_samples


def passed_sample_ids(experiment_status, experiment_samples):
    """Base sample names belonging to experiments where every sample passed."""
    passed = set()
    for exp_id, status in experiment_status.items():
        if status:
            passed.update(experiment_samples[exp_id])
    return passed


def failed_samples_detail(fastqc_data, experiment_status):
    """(sample_name, [failed_metric, ...]) for every sample belonging to a failed
    experiment, for the human-readable summary report."""
    failed = []
    for exp_id, status in experiment_status.items():
        if status:
            continue
        for sample_name, sample_data in fastqc_data.items():
            if experiment_id(sample_name) != exp_id:
                continue
            failed_metrics = [m for m in TARGET_METRICS if sample_data.get(m, "unknown") != "pass"]
            if failed_metrics:
                failed.append((sample_name, failed_metrics))
    return failed


def write_passed_samples(path, passed_ids):
    with open(path, "w") as f:
        for sample_id in sorted(passed_ids):
            f.write(sample_id + "\n")


def write_qc_summary_csv(path, qc_results):
    fieldnames = ["sample", *TARGET_METRICS, "overall_status"]
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for row in qc_results:
            writer.writerow(row)


def write_qc_summary_txt(path, fastqc_data, experiment_status, passed_ids, failed_detail, error=None):
    with open(path, "w") as f:
        f.write("QC Summary Report\n")
        f.write("=================\n")
        if error is not None:
            f.write("Total samples processed: 0\n")
            f.write("Samples passed: 0\n")
            f.write("Samples failed: 0\n")
            f.write(f"\nError processing MultiQC data: {error[0]}\n")
            f.write(f"Traceback: {error[1]}\n")
            return
        n_passed_experiments = sum(1 for v in experiment_status.values() if v)
        n_failed_experiments = sum(1 for v in experiment_status.values() if not v)
        f.write(f"Total individual samples processed: {len(fastqc_data)}\n")
        f.write(f"Total experiments processed: {len(experiment_status)}\n")
        f.write(f"Experiments passed: {n_passed_experiments}\n")
        f.write(f"Experiments failed: {n_failed_experiments}\n")
        f.write(f"Individual samples failed: {len(failed_detail)}\n")
        f.write(f"Unique sample IDs passed: {len(passed_ids)}\n")
        if failed_detail:
            f.write("\nFailed individual samples:\n")
            for sample, metrics in failed_detail:
                f.write(f"  {sample}: {', '.join(metrics)}\n")


def write_empty_outputs(outdir, error=None):
    write_passed_samples(f"{outdir}/passed_samples.txt", set())
    with open(f"{outdir}/qc_summary.csv", "w", newline="") as f:
        csv.writer(f).writerow(["sample", *TARGET_METRICS, "overall_status"])
    write_qc_summary_txt(f"{outdir}/qc_summary.txt", {}, {}, set(), [], error=error or ("No FastQC raw data found in MultiQC JSON", ""))


def parse_args(args=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--multiqc-json", required=True)
    parser.add_argument("--outdir", default=".")
    return parser.parse_args(args)


def main(args=None):
    args = parse_args(args)
    try:
        multiqc_data = json.load(open(args.multiqc_json))
        fastqc_data = extract_fastqc_data(multiqc_data)

        if not fastqc_data:
            write_empty_outputs(args.outdir)
            return 0

        qc_results, experiment_status, experiment_samples = evaluate_samples(fastqc_data)
        passed_ids = passed_sample_ids(experiment_status, experiment_samples)
        failed_detail = failed_samples_detail(fastqc_data, experiment_status)

        write_passed_samples(f"{args.outdir}/passed_samples.txt", passed_ids)
        write_qc_summary_csv(f"{args.outdir}/qc_summary.csv", qc_results)
        write_qc_summary_txt(f"{args.outdir}/qc_summary.txt", fastqc_data, experiment_status, passed_ids, failed_detail)
        return 0
    except Exception as e:
        write_empty_outputs(args.outdir, error=(str(e), traceback.format_exc()))
        return 0


if __name__ == "__main__":
    sys.exit(main())
