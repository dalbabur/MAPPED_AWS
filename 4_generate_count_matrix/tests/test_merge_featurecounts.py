import csv

import merge_featurecounts as mfc


def write_counts_file(path, bam_name, gene_ids, lengths, counts):
    with open(path, "w", newline="") as f:
        f.write("# Program:featureCounts v2.1.1; Command:...\n")
        writer = csv.writer(f, delimiter="\t")
        writer.writerow(["Geneid", "Chr", "Start", "End", "Strand", "Length", bam_name])
        for gene_id, length, count in zip(gene_ids, lengths, counts):
            writer.writerow([gene_id, "chr1", 1, length, "+", length, count])


def test_base_sample_name_and_experiment_id_match_salmon_variant():
    assert mfc.base_sample_name("SRX1_SRR1_val_1") == "SRX1_SRR1"
    assert mfc.experiment_id("SRX1_SRR1") == "SRX1"


def test_find_count_files_sorted(tmp_path):
    (tmp_path / "SRX2_SRR2_counts.txt").write_text("")
    (tmp_path / "SRX1_SRR1_counts.txt").write_text("")
    (tmp_path / "other.txt").write_text("")

    files = mfc.find_count_files(str(tmp_path))

    assert [f.split("/")[-1].split("\\")[-1] for f in files] == ["SRX1_SRR1_counts.txt", "SRX2_SRR2_counts.txt"]


def test_load_counts_file_reads_last_column_by_position(tmp_path):
    f = tmp_path / "SRX1_SRR1_counts.txt"
    write_counts_file(f, "SRX1_SRR1.sorted.bam", ["PP_RS00005", "PP_RS00010"], [873, 792], [265, 344])

    gene_ids, counts, lengths = mfc.load_counts_file(str(f))

    assert gene_ids == ["PP_RS00005", "PP_RS00010"]
    assert counts == [265, 344]
    assert lengths == [873, 792]


def test_group_by_experiment_skips_non_passed_samples(tmp_path):
    f1 = tmp_path / "SRX1_SRR1_counts.txt"
    write_counts_file(f1, "a.bam", ["g1"], [100], [10])
    f2 = tmp_path / "SRX2_SRR2_counts.txt"
    write_counts_file(f2, "b.bam", ["g1"], [100], [20])

    gene_ids, gene_lengths, experiment_data = mfc.group_by_experiment(
        [str(f1), str(f2)], passed_sample_ids={"SRX1_SRR1"}
    )

    assert gene_ids == ["g1"]
    assert gene_lengths == [100]
    assert list(experiment_data.keys()) == ["SRX1"]


def test_merge_experiment_runs_multi_run_sums_and_computes_tpm():
    gene_ids = ["g1", "g2"]
    gene_lengths = [100, 200]
    experiment_data = {"SRX1": [{"counts": [10, 0]}, {"counts": [10, 20]}]}

    final_counts, final_tpm = mfc.merge_experiment_runs(gene_ids, gene_lengths, experiment_data)

    assert final_counts["SRX1"] == [20, 20]
    rpk = [20 / 100, 20 / 200]
    scale = sum(rpk) / 1e6
    assert final_tpm["SRX1"] == [rpk[0] / scale, rpk[1] / scale]


def test_merge_experiment_runs_single_run_still_computes_tpm_unlike_salmon_variant():
    # featureCounts never reports TPM itself, so even a single run must have TPM derived
    # here (unlike merge_salmon_counts, which reuses Salmon's own TPM for single runs).
    gene_ids = ["g1"]
    gene_lengths = [100]
    experiment_data = {"SRX1": [{"counts": [50]}]}

    final_counts, final_tpm = mfc.merge_experiment_runs(gene_ids, gene_lengths, experiment_data)

    assert final_counts["SRX1"] == [50]
    assert final_tpm["SRX1"] == [1_000_000.0]


def test_main_end_to_end(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    write_counts_file(tmp_path / "SRX1_SRR1_counts.txt", "a.bam", ["g1", "g2"], [100, 200], [10, 20])
    (tmp_path / "passed.txt").write_text("SRX1_SRR1\n")

    mfc.main(["--passed-samples-file", "passed.txt"])

    assert (tmp_path / "counts.csv").read_text().splitlines()[1] == "g1,10"
    assert (tmp_path / "tpm.csv").exists()
    assert (tmp_path / "log_tpm.csv").exists()
