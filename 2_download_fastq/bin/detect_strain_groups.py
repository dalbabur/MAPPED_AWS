#!/usr/bin/env python3
"""Detect samples whose true bacterial strain differs from the queried --strain, and
resolve a correct reference genome accession for each distinct off-strain group found.

Step 1's --strain filter matches NCBI's free-text ScientificName field against the
queried strain -- but ScientificName (and tax_id) are submitter-supplied and can be
wrong. Real example that motivated this script: a whole study of P. putida strain UWC1
was deposited under KT2440's own NCBI tax_id (160488). No structured field can catch
this -- only free-text sample_title/sample_description ("P. putida UWC1 carrying...")
reveals the true strain.

Detection here is a curated allowlist match (--alias-config), not general NLP/regex
strain extraction -- an ad-hoc regex test against real metadata matched "F1"/"H2"
replicate labels as if they were strain codes, so free-text mining without a curated
list produces false positives. Each alias entry may pin an explicit
ref_accession_override for strains with no discoverable genome of their own (e.g. UWC1
itself has no whole-genome assembly at NCBI -- every hit under that name is a small
plasmid-only deposit -- so its config entry pins its documented parent strain's
accession instead, deliberately and visibly, not auto-guessed).

Reference resolution for strains without an override tries, in order: (1) NCBI's
Datasets REST API organism-taxon search, filtered to reject atypical/undersized results
(this is exactly the filter that would reject UWC1's own plasmid-only hits); (2) an
esearch/esummary fallback against NCBI's assembly database, which finds assemblies filed
under the bare species name with strain as a separate attribute (not addressable via the
taxon-name search alone -- this is how P. putida mt-2's real assemblies are found).
Anything neither step resolves is written to unresolved_strain_samples.csv rather than
silently forced onto the wrong reference or silently dropped.

Run directly by run_MAPPED.sh between Step 2 and Step 3 (not wired into
2_download_fastq/main.nf's Nextflow DAG), matching the existing
catalog/filter_processed_samples.py precedent of a standalone script invoked between
pipeline stages. Unlike the catalog/ scripts, this one works for both local and s3://
--outdir, since strain contamination isn't an S3-only problem.

Prints one line per resolved off-strain group to stdout:
    STRAIN_GROUP=<strain>|<ref_accession>|<resolution_method>|<samplesheet_override_path>
so run_MAPPED.sh can loop over them without parsing CSV itself.
"""

from __future__ import annotations

import argparse
import io
import json
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

import pandas as pd

STRAIN_EVIDENCE_FIELDS = [
    "sample_title",
    "experiment_title",
    "study_title",
    "sample_description",
    "sample_alias",
]

DEFAULT_MIN_GENOME_SIZE = 1_000_000

NCBI_DATASETS_TAXON_URL = "https://api.ncbi.nlm.nih.gov/datasets/v2/genome/taxon/{query}/dataset_report"
NCBI_ESEARCH_URL = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi"
NCBI_ESUMMARY_URL = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi"

REF_ACCESSION_RE = re.compile(r"^GC[AF]_[0-9]+\.[0-9]+$")
META_TOTAL_LENGTH_RE = re.compile(r'category="total_length" sequence_tag="all">(\d+)<')


# ---- local/S3 I/O helpers (no boto3/awswrangler needed -- plain `aws s3 cp`, matching
# catalog/filter_processed_samples.py's s3_cat(), extended to also handle local paths
# since strain contamination isn't an S3-only problem) ----


def read_text_any(path: str) -> str | None:
    if path.startswith("s3://"):
        result = subprocess.run(["aws", "s3", "cp", path, "-"], capture_output=True, text=True)
        return result.stdout if result.returncode == 0 else None
    p = Path(path)
    return p.read_text(encoding="utf-8") if p.exists() else None


def write_text_any(text: str, path: str) -> None:
    if path.startswith("s3://"):
        subprocess.run(["aws", "s3", "cp", "-", path], input=text, text=True, check=True)
    else:
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        Path(path).write_text(text, encoding="utf-8")


def read_csv_any(path: str, **kwargs) -> pd.DataFrame | None:
    text = read_text_any(path)
    if not text or not text.strip():
        return None
    return pd.read_csv(io.StringIO(text), **kwargs)


def write_csv_any(df: pd.DataFrame, path: str) -> None:
    buf = io.StringIO()
    df.to_csv(buf, index=False)
    write_text_any(buf.getvalue(), path)


def path_join_any(base: str, *parts: str) -> str:
    return "/".join([base.rstrip("/"), *parts])


def strain_slug(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", name.strip())


def load_alias_config(path: str, organism: str) -> list[dict]:
    text = read_text_any(path)
    if not text:
        return []
    config = json.loads(text)
    # Case-insensitive lookup -- a mismatch here (e.g. "pseudomonas putida" vs
    # "Pseudomonas putida") would otherwise silently disable detection with no error.
    organism_lower = organism.strip().lower()
    for key, aliases in config.items():
        if key.strip().lower() == organism_lower:
            return aliases
    return []


# ---- detection (pure) ----


def detect_strain_for_row(row: dict, default_strain: str, aliases: list[dict]) -> tuple[str, str]:
    """Case-insensitive substring search of each alias against the row's free-text
    evidence fields. First match (in config order) wins. No match keeps the row at the
    default/queried strain."""
    evidence_text = " | ".join(str(row.get(f, "") or "") for f in STRAIN_EVIDENCE_FIELDS)
    evidence_lower = evidence_text.lower()
    for entry in aliases:
        alias = entry.get("alias", "")
        if alias and alias.lower() in evidence_lower:
            return entry.get("canonical_strain", alias), f"matched alias '{alias}'"
    return default_strain, "default (no alias match)"


def build_strain_groups(samplesheet_df: pd.DataFrame, default_strain: str, aliases: list[dict]) -> pd.DataFrame:
    records = []
    for row in samplesheet_df.to_dict(orient="records"):
        detected, evidence = detect_strain_for_row(row, default_strain, aliases)
        records.append({"id": row.get("id"), "detected_strain": detected, "evidence": evidence})
    return pd.DataFrame(records, columns=["id", "detected_strain", "evidence"])


# ---- reference resolution ----


def fetch_json(url: str) -> dict | None:
    try:
        with urllib.request.urlopen(url, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        return None


def fetch_datasets_taxon_report(organism: str, strain: str) -> dict | None:
    query = urllib.parse.quote(f"{organism} {strain}")
    return fetch_json(NCBI_DATASETS_TAXON_URL.format(query=query))


def pick_best_assembly(report: dict | None, min_genome_size: int) -> dict | None:
    """Pure. Rejects atypical (e.g. plasmid-only) and undersized results -- exactly the
    filter that rejects UWC1's own all-plasmid hits under this endpoint. Prefers RefSeq
    over GenBank, then largest genome."""
    if not report or not report.get("reports"):
        return None
    candidates = []
    for r in report["reports"]:
        info = r.get("assembly_info", {})
        stats = r.get("assembly_stats", {})
        if info.get("atypical", {}).get("is_atypical", False):
            continue
        try:
            size = float(stats.get("total_sequence_length", 0))
        except (TypeError, ValueError):
            continue
        if size < min_genome_size:
            continue
        accession = r.get("accession")
        if not accession:
            continue
        candidates.append(
            {
                "accession": accession,
                "total_sequence_length": size,
                "is_refseq": r.get("source_database") == "SOURCE_DATABASE_REFSEQ",
            }
        )
    if not candidates:
        return None
    candidates.sort(key=lambda c: (c["is_refseq"], c["total_sequence_length"]), reverse=True)
    return candidates[0]


def fetch_esearch_esummary_fallback(organism: str, strain: str) -> dict | None:
    term = urllib.parse.quote(f"{organism} {strain}")
    esearch_result = fetch_json(f"{NCBI_ESEARCH_URL}?db=assembly&term={term}&retmode=json")
    if not esearch_result:
        return None
    idlist = esearch_result.get("esearchresult", {}).get("idlist", [])
    if not idlist:
        return None
    ids = ",".join(idlist)
    return fetch_json(f"{NCBI_ESUMMARY_URL}?db=assembly&id={ids}&retmode=json")


def pick_best_assembly_from_esummary(esummary_json: dict | None, strain: str, min_genome_size: int) -> dict | None:
    """Pure. Matches esummary's infraspecific strain attribute (this is the path that
    actually finds mt-2's real assemblies, since they're not addressable by organism-name
    search alone -- filed under plain "Pseudomonas putida" with strain as a separate
    field). Genome size isn't a top-level esummary field; it's embedded in a "meta" XML
    blob as a <Stat category="total_length"> element, extracted via regex rather than a
    full XML parser since it's the only field needed from that blob.

    Assembly completeness is weighed ahead of raw size: verified against mt-2's two real
    RefSeq assemblies, the larger one (GCF_900183025.1, 6.31Mb) is only "Chromosome"-level
    while the smaller one (GCF_032681205.1, 6.18Mb) is a full "Complete Genome" -- picking
    by size alone would have preferred the lower-quality assembly."""
    if not esummary_json:
        return None
    result = esummary_json.get("result", {})
    strain_lower = strain.lower()
    candidates = []
    for uid in result.get("uids", []):
        r = result.get(uid, {})
        infraspecies = r.get("biosource", {}).get("infraspecieslist", [])
        if not any(strain_lower in str(x.get("sub_value", "")).lower() for x in infraspecies):
            continue
        accession = r.get("assemblyaccession")
        if not accession:
            continue
        size_match = META_TOTAL_LENGTH_RE.search(r.get("meta", "") or "")
        size = float(size_match.group(1)) if size_match else None
        if size is not None and size < min_genome_size:
            continue
        candidates.append(
            {
                "accession": accession,
                "is_complete_genome": r.get("assemblystatus") == "Complete Genome",
                "is_refseq": accession.startswith("GCF_"),
                "size": size or 0,
            }
        )
    if not candidates:
        return None
    candidates.sort(key=lambda c: (c["is_complete_genome"], c["is_refseq"], c["size"]), reverse=True)
    return candidates[0]


def resolve_reference_for_strain(organism: str, strain: str, alias_entry: dict | None) -> dict:
    min_genome_size = (alias_entry or {}).get("min_genome_size") or DEFAULT_MIN_GENOME_SIZE
    result = {"strain": strain, "ref_accession": None, "resolution_method": "unresolved", "status": "unresolved"}

    override = (alias_entry or {}).get("ref_accession_override")
    if override:
        if REF_ACCESSION_RE.match(override):
            return {"strain": strain, "ref_accession": override, "resolution_method": "manual_override", "status": "resolved"}
        return {**result, "resolution_method": "invalid_override"}

    best = pick_best_assembly(fetch_datasets_taxon_report(organism, strain), min_genome_size)
    if best:
        return {"strain": strain, "ref_accession": best["accession"], "resolution_method": "datasets_taxon", "status": "resolved"}

    best = pick_best_assembly_from_esummary(fetch_esearch_esummary_fallback(organism, strain), strain, min_genome_size)
    if best:
        return {"strain": strain, "ref_accession": best["accession"], "resolution_method": "esearch_esummary", "status": "resolved"}

    return result


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--outdir", required=True)
    parser.add_argument("--organism", required=True)
    parser.add_argument("--strain", default="", help="The queried strain (if any); rows detected as anything else are off-strain.")
    default_alias_config = Path(__file__).resolve().parent.parent / "assets" / "strain_aliases.json"
    parser.add_argument("--alias-config", default=str(default_alias_config))
    args = parser.parse_args(argv)

    outdir = args.outdir.rstrip("/")
    default_strain = args.strain.strip() or args.organism

    samplesheet_path = path_join_any(outdir, "samplesheet", "samplesheet_download.csv")
    samplesheet_df = read_csv_any(samplesheet_path, dtype=str)
    if samplesheet_df is None:
        print(f"NOTE: {samplesheet_path} not found or empty -- skipping strain detection.")
        return 0

    aliases = load_alias_config(args.alias_config, args.organism)
    if not aliases:
        print(f"No strain aliases configured for organism '{args.organism}' -- nothing to detect.")
        return 0

    strain_groups_df = build_strain_groups(samplesheet_df, default_strain, aliases)
    write_csv_any(strain_groups_df, path_join_any(outdir, "metadata", "strain_groups.csv"))

    off_strain_df = strain_groups_df[strain_groups_df["detected_strain"] != default_strain]
    if off_strain_df.empty:
        print("No off-strain samples detected.")
        return 0

    print(f"Detected {len(off_strain_df)} off-strain sample(s) across {off_strain_df['detected_strain'].nunique()} strain(s):")

    alias_by_canonical = {a.get("canonical_strain", a.get("alias")): a for a in aliases}
    merged_df = samplesheet_df.merge(strain_groups_df, on="id", how="inner")

    reference_rows = []
    unresolved_frames = []
    exclude_ids: list[str] = []

    for strain, group in off_strain_df.groupby("detected_strain"):
        ids = group["id"].tolist()
        exclude_ids.extend(ids)
        resolution = resolve_reference_for_strain(args.organism, strain, alias_by_canonical.get(strain))
        reference_rows.append(resolution)
        subset_df = merged_df[merged_df["id"].isin(ids)][samplesheet_df.columns]

        if resolution["status"] == "resolved":
            print(f"  {strain}: {len(ids)} sample(s) -> {resolution['ref_accession']} ({resolution['resolution_method']})")
            override_path = path_join_any(outdir, "metadata", "samplesheet_by_strain", f"{strain_slug(strain)}.csv")
            write_csv_any(subset_df, override_path)
            print(f"STRAIN_GROUP={strain}|{resolution['ref_accession']}|{resolution['resolution_method']}|{override_path}")
        else:
            print(f"  {strain}: {len(ids)} sample(s) -- UNRESOLVED, no reference genome found. See unresolved_strain_samples.csv.")
            unresolved_frames.append(subset_df)

    write_csv_any(
        pd.DataFrame(reference_rows, columns=["strain", "ref_accession", "resolution_method", "status"]),
        path_join_any(outdir, "metadata", "strain_reference_map.csv"),
    )
    if unresolved_frames:
        write_csv_any(pd.concat(unresolved_frames, ignore_index=True), path_join_any(outdir, "metadata", "unresolved_strain_samples.csv"))
    write_text_any("\n".join(exclude_ids) + "\n" if exclude_ids else "", path_join_any(outdir, "metadata", "exclude_ids_primary.txt"))

    return 0


if __name__ == "__main__":
    sys.exit(main())
