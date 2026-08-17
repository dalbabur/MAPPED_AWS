#!/usr/bin/env python
"""Filter the original samplesheet down to only the samples that passed QC.

Mirrors the original inline bash/awk logic, with one fix: the 'id' column
value is compared after stripping a leading/trailing double-quote, so this
matches regardless of whether the source CSV quotes its id values. The
original always wrapped the *comparison* value in literal quotes instead of
stripping them from the field, so it only ever matched a quoted CSV -- with
today's unquoted samplesheet_download.csv it silently matched zero rows
every time (errorStrategy 'ignore' hid the resulting empty output).
"""

from __future__ import annotations

import argparse
import csv
import sys


def read_passed_sample_ids(path):
    with open(path) as f:
        return [line.strip() for line in f if line.strip()]


def strip_quotes(value):
    """Remove a single leading/trailing double-quote, if both are present."""
    if value and len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        return value[1:-1]
    return value


def find_id_column(fieldnames):
    for name in fieldnames or []:
        if strip_quotes(name.strip()) == "id":
            return name
    return None


def read_samplesheet_rows(path):
    """Read the CSV, dropping blank lines first (mirrors the original's
    `grep -v '^[[:space:]]*$'` pass before parsing)."""
    with open(path, newline="") as f:
        lines = [line for line in f if line.strip()]
    reader = csv.DictReader(lines)
    return reader.fieldnames or [], list(reader)


def filter_rows(rows, id_col, passed_ids):
    """For each passed sample ID (in file order), collect every matching row in
    original CSV order, then drop exact-duplicate rows while preserving order --
    mirrors the original's per-ID awk scan followed by `awk '!seen[$0]++'`."""
    matched = []
    for sample_id in passed_ids:
        for row in rows:
            if strip_quotes((row.get(id_col) or "").strip()) == sample_id:
                matched.append(row)

    seen = set()
    result = []
    for row in matched:
        key = tuple(row.items())
        if key not in seen:
            seen.add(key)
            result.append(row)
    return result


def write_samplesheet(path, fieldnames, rows):
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def parse_args(args=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samplesheet", required=True)
    parser.add_argument("--passed-samples-file", required=True)
    return parser.parse_args(args)


def main(args=None):
    args = parse_args(args)
    fieldnames, rows = read_samplesheet_rows(args.samplesheet)
    passed_ids = read_passed_sample_ids(args.passed_samples_file)
    original_count = len(rows)

    if not passed_ids:
        print("WARNING: No samples passed QC filters!")
        filtered_rows = []
    else:
        id_col = find_id_column(fieldnames)
        if id_col is None:
            print("ERROR: Could not find 'id' column in samplesheet")
            return 1
        filtered_rows = filter_rows(rows, id_col, passed_ids)

    write_samplesheet("samplesheet.csv", fieldnames, filtered_rows)

    filtered_count = len(filtered_rows)
    print(f"Original samples: {original_count}")
    print(f"Filtered samples: {filtered_count}")
    print(f"Samples removed: {original_count - filtered_count}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
