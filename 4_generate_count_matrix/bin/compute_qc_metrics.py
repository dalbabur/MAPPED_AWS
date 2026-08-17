#!/usr/bin/env python
"""Compute run-wide coverage/QC metrics from raw per-sample Bowtie2/featureCounts output.

None of this is captured anywhere today -- BOWTIE2_ALIGN's alignment-rate summary
(bowtie2's stderr) and featureCounts' own '<sample>_counts.txt.summary' are both
discarded once their task's work directory is cleaned up. This reads them plus the raw
'<sample>_counts.txt' files and the reference GFF (for each gene's gene_biotype) to
report, per run:
  - mapping rate: fraction of reads Bowtie2 aligned to the genome at all.
  - assignment rate: fraction of reads featureCounts assigned to *some* gene feature.
  - rRNA/tRNA fraction: of reads assigned to a gene, what fraction landed on an rRNA or
    tRNA gene rather than a protein-coding one -- the concrete, measurable number behind
    "this dataset's low mapping rate is un-depleted rRNA/tRNA, not a reference problem"
    (see 4_generate_count_matrix/README.md and the CDS-vs-full-transcript investigation
    this metric grew out of).

Bowtie2-path only: EXTRACT_CDS's protein-coding-only reference (the Salmon path)
structurally cannot see rRNA/tRNA reads at all, so this metric is meaningless there.
"""

from __future__ import annotations

import argparse
import csv
import glob
import json
import os
import re
import sys
from collections import defaultdict

MAPPING_RATE_RE = re.compile(r"^([\d.]+)% overall alignment rate")
GENE_LOCUS_TAG_RE = re.compile(r"locus_tag=([^;]+)")
GENE_BIOTYPE_RE = re.compile(r"gene_biotype=([^;]+)")


def find_files(pattern, search_dir="."):
    return sorted(glob.glob(os.path.join(search_dir, pattern)))


def sample_name_from_bowtie2_log(path):
    return os.path.basename(path)[: -len(".bowtie2.log")]


def sample_name_from_fc_summary(path):
    return os.path.basename(path)[: -len("_counts.txt.summary")]


def sample_name_from_counts_file(path):
    return os.path.basename(path)[: -len("_counts.txt")]


def parse_bowtie2_mapping_rate(path):
    """Bowtie2's stderr ends with a line like '95.23% overall alignment rate'."""
    with open(path) as f:
        for line in f:
            m = MAPPING_RATE_RE.search(line.strip())
            if m:
                return float(m.group(1))
    return None


def parse_featurecounts_summary(path):
    """(assigned, total) read counts from a featureCounts '<sample>_counts.txt.summary'
    file: a 'Status <tab> <bam path>' header, then one row per assignment outcome."""
    assigned = 0
    total = 0
    with open(path) as f:
        reader = csv.DictReader(f, delimiter="\t")
        if not reader.fieldnames or len(reader.fieldnames) < 2:
            return 0, 0
        count_col = reader.fieldnames[-1]
        for row in reader:
            try:
                count = int(row[count_col])
            except (TypeError, ValueError):
                continue
            total += count
            if row.get("Status") == "Assigned":
                assigned = count
    return assigned, total


def parse_gff_biotypes(gff_path):
    """locus_tag -> gene_biotype, read from every 'gene' feature line's attribute column."""
    biotypes = {}
    with open(gff_path) as f:
        for line in f:
            if line.startswith("#"):
                continue
            fields = line.rstrip("\n").split("\t")
            if len(fields) < 9 or fields[2] != "gene":
                continue
            locus_match = GENE_LOCUS_TAG_RE.search(fields[8])
            biotype_match = GENE_BIOTYPE_RE.search(fields[8])
            if locus_match and biotype_match:
                biotypes[locus_match.group(1)] = biotype_match.group(1)
    return biotypes


def classify_biotype(biotype):
    """Bucket a gene_biotype into 'protein_coding', 'rRNA', 'tRNA', or 'other'
    (pseudogene, ncRNA, tmRNA, ... -- everything not individually broken out)."""
    if biotype in ("protein_coding", "rRNA", "tRNA"):
        return biotype
    return "other"


def sum_counts_by_biotype(counts_file, biotypes):
    """Per-biotype-bucket sum of a featureCounts '<sample>_counts.txt' file's read
    counts. The file has a '# Program:featureCounts ...' comment line, then a header
    (Geneid, Chr, Start, End, Strand, Length, <bam path>); the count column is selected
    by position since its header is whatever BAM path was passed to featureCounts."""
    with open(counts_file) as f:
        lines = [line for line in f if not line.startswith("#")]
    reader = csv.DictReader(lines, delimiter="\t")
    if not reader.fieldnames:
        return {}
    count_col = reader.fieldnames[-1]
    sums = defaultdict(int)
    for row in reader:
        try:
            count = int(row[count_col])
        except (TypeError, ValueError):
            continue
        bucket = classify_biotype(biotypes.get(row.get("Geneid"), "other"))
        sums[bucket] += count
    return dict(sums)


def compute_per_sample_metrics(bowtie2_logs, fc_summaries, counts_files, biotypes):
    """One metrics dict per sample seen in any of the three input sets."""
    mapping_rates = {sample_name_from_bowtie2_log(p): parse_bowtie2_mapping_rate(p) for p in bowtie2_logs}
    assignment = {sample_name_from_fc_summary(p): parse_featurecounts_summary(p) for p in fc_summaries}
    biotype_sums = {sample_name_from_counts_file(p): sum_counts_by_biotype(p, biotypes) for p in counts_files}

    samples = sorted(set(mapping_rates) | set(assignment) | set(biotype_sums))
    per_sample = []
    for sample in samples:
        assigned, total = assignment.get(sample, (0, 0))
        sums = biotype_sums.get(sample, {})
        assigned_reads = sum(sums.values())
        per_sample.append({
            "sample": sample,
            "mapping_rate_pct": mapping_rates.get(sample),
            "assignment_rate_pct": round(100.0 * assigned / total, 4) if total else None,
            "rrna_fraction_pct": round(100.0 * sums.get("rRNA", 0) / assigned_reads, 4) if assigned_reads else None,
            "trna_fraction_pct": round(100.0 * sums.get("tRNA", 0) / assigned_reads, 4) if assigned_reads else None,
        })
    return per_sample


def mean_of(values):
    values = [v for v in values if v is not None]
    return round(sum(values) / len(values), 4) if values else None


def summarize(per_sample):
    return {
        "n_samples": len(per_sample),
        "mean_mapping_rate_pct": mean_of([s["mapping_rate_pct"] for s in per_sample]),
        "mean_assignment_rate_pct": mean_of([s["assignment_rate_pct"] for s in per_sample]),
        "mean_rrna_fraction_pct": mean_of([s["rrna_fraction_pct"] for s in per_sample]),
        "mean_trna_fraction_pct": mean_of([s["trna_fraction_pct"] for s in per_sample]),
    }


def parse_args(args=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gff", required=True)
    parser.add_argument("--search-dir", default=".")
    parser.add_argument("--output", default="qc_metrics.json")
    return parser.parse_args(args)


def main(args=None):
    args = parse_args(args)

    biotypes = parse_gff_biotypes(args.gff)
    bowtie2_logs = find_files("*.bowtie2.log", args.search_dir)
    fc_summaries = find_files("*_counts.txt.summary", args.search_dir)
    counts_files = find_files("*_counts.txt", args.search_dir)

    per_sample = compute_per_sample_metrics(bowtie2_logs, fc_summaries, counts_files, biotypes)
    summary = summarize(per_sample)

    with open(args.output, "w") as f:
        json.dump({"summary": summary, "per_sample": per_sample}, f, indent=2)

    print(f"QC metrics ({summary['n_samples']} samples): {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
