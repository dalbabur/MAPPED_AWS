import json

import compute_qc_metrics as qc

BOWTIE2_LOG = """\
100 reads; of these:
  100 (100.00%) were paired; of these:
    5 (5.00%) aligned concordantly 0 times
    90 (90.00%) aligned concordantly exactly 1 time
    5 (5.00%) aligned concordantly >1 times
    ----
    5 pairs aligned concordantly 0 times; of these:
      2 (40.00%) aligned discordantly 1 time
98.50% overall alignment rate
"""

FC_SUMMARY = """\
Status\tSRX1.sorted.bam
Assigned\t800
Unassigned_Unmapped\t50
Unassigned_MultiMapping\t30
Unassigned_NoFeatures\t100
Unassigned_Ambiguity\t20
"""

FC_COUNTS = """\
# Program:featureCounts v2.1.1; Command:...
Geneid\tChr\tStart\tEnd\tStrand\tLength\tSRX1.sorted.bam
PP_RS00005\tNC_1\t1\t100\t+\t100\t700
PP_RS00825\tNC_1\t200\t300\t+\t100\t80
PP_RS00830\tNC_1\t400\t500\t+\t100\t20
"""

GFF = """\
##gff-version 3
NC_1\tRefSeq\tgene\t1\t100\t.\t+\t.\tID=gene-PP_RS00005;gene_biotype=protein_coding;locus_tag=PP_RS00005
NC_1\tRefSeq\tCDS\t1\t100\t.\t+\t0\tID=cds-PP_RS00005;gene_biotype=protein_coding;locus_tag=PP_RS00005
NC_1\tRefSeq\tgene\t200\t300\t.\t+\t.\tID=gene-PP_RS00825;gene_biotype=rRNA;locus_tag=PP_RS00825
NC_1\tRefSeq\tgene\t400\t500\t.\t+\t.\tID=gene-PP_RS00830;gene_biotype=rRNA;locus_tag=PP_RS00830
"""


def test_parse_bowtie2_mapping_rate(tmp_path):
    log = tmp_path / "SRX1.bowtie2.log"
    log.write_text(BOWTIE2_LOG)
    assert qc.parse_bowtie2_mapping_rate(str(log)) == 98.50


def test_parse_bowtie2_mapping_rate_missing_line_returns_none(tmp_path):
    log = tmp_path / "SRX1.bowtie2.log"
    log.write_text("no summary line here\n")
    assert qc.parse_bowtie2_mapping_rate(str(log)) is None


def test_parse_featurecounts_summary(tmp_path):
    summary = tmp_path / "SRX1_counts.txt.summary"
    summary.write_text(FC_SUMMARY)
    assigned, total = qc.parse_featurecounts_summary(str(summary))
    assert assigned == 800
    assert total == 1000


def test_parse_gff_biotypes_only_reads_gene_features(tmp_path):
    # GFF fixture includes a CDS line for PP_RS00005 too -- must not double-count or
    # otherwise be confused by non-'gene' feature rows sharing the same locus_tag.
    gff = tmp_path / "genomic.gff"
    gff.write_text(GFF)
    biotypes = qc.parse_gff_biotypes(str(gff))
    assert biotypes == {
        "PP_RS00005": "protein_coding",
        "PP_RS00825": "rRNA",
        "PP_RS00830": "rRNA",
    }


def test_classify_biotype():
    assert qc.classify_biotype("protein_coding") == "protein_coding"
    assert qc.classify_biotype("rRNA") == "rRNA"
    assert qc.classify_biotype("tRNA") == "tRNA"
    assert qc.classify_biotype("pseudogene") == "other"
    assert qc.classify_biotype("ncRNA") == "other"


def test_sum_counts_by_biotype(tmp_path):
    counts = tmp_path / "SRX1_counts.txt"
    counts.write_text(FC_COUNTS)
    biotypes = {"PP_RS00005": "protein_coding", "PP_RS00825": "rRNA", "PP_RS00830": "rRNA"}
    sums = qc.sum_counts_by_biotype(str(counts), biotypes)
    assert sums == {"protein_coding": 700, "rRNA": 100}


def test_sum_counts_by_biotype_unknown_gene_is_other(tmp_path):
    counts = tmp_path / "SRX1_counts.txt"
    counts.write_text(FC_COUNTS)
    sums = qc.sum_counts_by_biotype(str(counts), {})  # no biotype info at all
    assert sums == {"other": 800}


def test_mean_of_skips_none():
    assert qc.mean_of([10.0, None, 20.0]) == 15.0


def test_mean_of_empty_list_is_none():
    assert qc.mean_of([]) is None
    assert qc.mean_of([None, None]) is None


def test_compute_per_sample_metrics(tmp_path):
    (tmp_path / "SRX1.bowtie2.log").write_text(BOWTIE2_LOG)
    (tmp_path / "SRX1_counts.txt.summary").write_text(FC_SUMMARY)
    (tmp_path / "SRX1_counts.txt").write_text(FC_COUNTS)
    biotypes = {"PP_RS00005": "protein_coding", "PP_RS00825": "rRNA", "PP_RS00830": "rRNA"}

    per_sample = qc.compute_per_sample_metrics(
        [str(tmp_path / "SRX1.bowtie2.log")],
        [str(tmp_path / "SRX1_counts.txt.summary")],
        [str(tmp_path / "SRX1_counts.txt")],
        biotypes,
    )

    assert len(per_sample) == 1
    entry = per_sample[0]
    assert entry["sample"] == "SRX1"
    assert entry["mapping_rate_pct"] == 98.50
    assert entry["assignment_rate_pct"] == 80.0
    assert entry["rrna_fraction_pct"] == 12.5
    assert entry["trna_fraction_pct"] == 0.0


def test_compute_per_sample_metrics_missing_bowtie2_log_is_none(tmp_path):
    # Sample only has a counts file, no bowtie2 log (e.g. alignment failed but
    # featureCounts still ran against a stale/empty BAM) -- should not crash, just
    # report mapping_rate_pct as None for that sample rather than dropping it.
    (tmp_path / "SRX2_counts.txt.summary").write_text(FC_SUMMARY.replace("SRX1", "SRX2"))
    (tmp_path / "SRX2_counts.txt").write_text(FC_COUNTS.replace("SRX1", "SRX2"))

    per_sample = qc.compute_per_sample_metrics(
        [],
        [str(tmp_path / "SRX2_counts.txt.summary")],
        [str(tmp_path / "SRX2_counts.txt")],
        {"PP_RS00005": "protein_coding", "PP_RS00825": "rRNA", "PP_RS00830": "rRNA"},
    )

    assert per_sample[0]["sample"] == "SRX2"
    assert per_sample[0]["mapping_rate_pct"] is None
    assert per_sample[0]["assignment_rate_pct"] == 80.0


def test_summarize():
    per_sample = [
        {"mapping_rate_pct": 90.0, "assignment_rate_pct": 80.0, "rrna_fraction_pct": 10.0, "trna_fraction_pct": 1.0},
        {"mapping_rate_pct": 80.0, "assignment_rate_pct": 70.0, "rrna_fraction_pct": 20.0, "trna_fraction_pct": 3.0},
    ]
    summary = qc.summarize(per_sample)
    assert summary == {
        "n_samples": 2,
        "mean_mapping_rate_pct": 85.0,
        "mean_assignment_rate_pct": 75.0,
        "mean_rrna_fraction_pct": 15.0,
        "mean_trna_fraction_pct": 2.0,
    }


def test_main_end_to_end(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    (tmp_path / "SRX1.bowtie2.log").write_text(BOWTIE2_LOG)
    (tmp_path / "SRX1_counts.txt.summary").write_text(FC_SUMMARY)
    (tmp_path / "SRX1_counts.txt").write_text(FC_COUNTS)
    (tmp_path / "genomic.gff").write_text(GFF)

    rc = qc.main(["--gff", "genomic.gff"])

    assert rc == 0
    result = json.loads((tmp_path / "qc_metrics.json").read_text())
    assert result["summary"]["n_samples"] == 1
    assert result["summary"]["mean_mapping_rate_pct"] == 98.50
    assert result["summary"]["mean_rrna_fraction_pct"] == 12.5
    assert result["per_sample"][0]["sample"] == "SRX1"


def test_main_no_matching_files_writes_empty_summary(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    (tmp_path / "genomic.gff").write_text(GFF)

    rc = qc.main(["--gff", "genomic.gff"])

    assert rc == 0
    result = json.loads((tmp_path / "qc_metrics.json").read_text())
    assert result["summary"]["n_samples"] == 0
    assert result["summary"]["mean_mapping_rate_pct"] is None
    assert result["per_sample"] == []
