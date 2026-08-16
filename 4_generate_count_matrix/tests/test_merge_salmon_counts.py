import csv

import merge_salmon_counts as msc


def write_quant_sf(path, names, lengths, eff_lengths, tpm, num_reads):
    with open(path, "w", newline="") as f:
        writer = csv.writer(f, delimiter="\t")
        writer.writerow(["Name", "Length", "EffectiveLength", "TPM", "NumReads"])
        for row in zip(names, lengths, eff_lengths, tpm, num_reads):
            writer.writerow(row)


def make_quant_dir(tmp_path, dirname, *, with_flag=True, with_quant=True, **quant_kwargs):
    d = tmp_path / dirname
    d.mkdir()
    if with_quant:
        write_quant_sf(
            d / "quant.sf",
            names=quant_kwargs.get("names", ["geneA", "geneB"]),
            lengths=quant_kwargs.get("lengths", [100, 200]),
            eff_lengths=quant_kwargs.get("eff_lengths", [80, 180]),
            tpm=quant_kwargs.get("tpm", [10.0, 20.0]),
            num_reads=quant_kwargs.get("num_reads", [5, 15]),
        )
    if with_flag:
        (d / "salmon_success.flag").touch()
    return d


def test_base_sample_name_strips_trimgalore_suffixes():
    assert msc.base_sample_name("SRX1_SRR1_val_1") == "SRX1_SRR1"
    assert msc.base_sample_name("SRX1_SRR1_val_2") == "SRX1_SRR1"
    assert msc.base_sample_name("SRX1_SRR1_trimmed") == "SRX1_SRR1"
    assert msc.base_sample_name("SRX1_SRR1") == "SRX1_SRR1"


def test_experiment_id_takes_prefix_before_first_underscore():
    assert msc.experiment_id("SRX1_SRR1") == "SRX1"
    assert msc.experiment_id("DRX9_DRR9_val_1") == "DRX9"


def test_read_passed_sample_ids_missing_file_returns_empty_set(tmp_path):
    assert msc.read_passed_sample_ids(str(tmp_path / "nope.txt")) == set()


def test_read_passed_sample_ids_reads_lines_skipping_blank(tmp_path):
    f = tmp_path / "passed.txt"
    f.write_text("SRX1\n\nSRX2\n")
    assert msc.read_passed_sample_ids(str(f)) == {"SRX1", "SRX2"}


def test_find_successful_quant_dirs_filters_incomplete(tmp_path):
    make_quant_dir(tmp_path, "SRX1_SRR1_quant")
    make_quant_dir(tmp_path, "SRX2_SRR2_quant", with_flag=False)
    make_quant_dir(tmp_path, "SRX3_SRR3_quant", with_quant=False)
    (tmp_path / "not_a_quant_dir").mkdir()

    successful, failed = msc.find_successful_quant_dirs(str(tmp_path))

    assert len(successful) == 1
    assert successful[0].endswith("SRX1_SRR1_quant")
    assert sorted(failed) == ["SRX2_SRR2", "SRX3_SRR3"]


def test_group_by_experiment_skips_non_passed_samples(tmp_path):
    d1 = make_quant_dir(tmp_path, "SRX1_SRR1_quant")
    make_quant_dir(tmp_path, "SRX2_SRR2_quant")

    gene_ids, experiment_data = msc.group_by_experiment([str(d1)], passed_sample_ids={"SRX1_SRR1"})

    assert gene_ids == ["geneA", "geneB"]
    assert list(experiment_data.keys()) == ["SRX1"]


def test_group_by_experiment_groups_multiple_runs_under_one_experiment(tmp_path):
    d1 = make_quant_dir(tmp_path, "SRX1_SRR1_quant", num_reads=[5, 15])
    d2 = make_quant_dir(tmp_path, "SRX1_SRR2_quant", num_reads=[3, 7])

    gene_ids, experiment_data = msc.group_by_experiment(
        [str(d1), str(d2)], passed_sample_ids={"SRX1_SRR1", "SRX1_SRR2"}
    )

    assert len(experiment_data["SRX1"]) == 2


def test_merge_experiment_runs_single_run_passes_through_unchanged():
    gene_ids = ["geneA", "geneB"]
    experiment_data = {"SRX1": [{"counts": [5, 15], "tpm": [10.0, 20.0], "length": [100, 200]}]}

    final_counts, final_tpm = msc.merge_experiment_runs(gene_ids, experiment_data)

    assert final_counts["SRX1"] == [5, 15]
    assert final_tpm["SRX1"] == [10.0, 20.0]


def test_merge_experiment_runs_multi_run_sums_counts_and_recomputes_tpm():
    gene_ids = ["geneA", "geneB"]
    experiment_data = {
        "SRX1": [
            {"counts": [10, 0], "tpm": [999.0, 0.0], "length": [100, 200]},
            {"counts": [10, 20], "tpm": [999.0, 999.0], "length": [100, 200]},
        ]
    }

    final_counts, final_tpm = msc.merge_experiment_runs(gene_ids, experiment_data)

    assert final_counts["SRX1"] == [20, 20]
    # RPK = counts/length = [20/100, 20/200] = [0.2, 0.1]; scale = sum(RPK)/1e6
    rpk = [20 / 100, 20 / 200]
    scale = sum(rpk) / 1e6
    expected_tpm = [rpk[0] / scale, rpk[1] / scale]
    assert final_tpm["SRX1"] == expected_tpm
    assert abs(sum(final_tpm["SRX1"]) - 1_000_000) < 1e-6


def test_merge_experiment_runs_handles_zero_length_gene_without_dividing_by_zero():
    gene_ids = ["geneA"]
    experiment_data = {"SRX1": [{"counts": [5], "tpm": [1.0], "length": [0]}, {"counts": [3], "tpm": [1.0], "length": [0]}]}

    final_counts, final_tpm = msc.merge_experiment_runs(gene_ids, experiment_data)

    assert final_counts["SRX1"] == [8]
    assert final_tpm["SRX1"] == [0]


def test_write_matrices_no_data_writes_header_only_files(tmp_path):
    msc.write_matrices(None, {}, {}, outdir=str(tmp_path))

    for name in ("counts.csv", "tpm.csv", "log_tpm.csv"):
        assert (tmp_path / name).read_text() == "GeneID\n"


def test_write_matrices_writes_expected_csv_content(tmp_path):
    gene_ids = ["geneA", "geneB"]
    final_counts = {"SRX1": [5, 15], "SRX2": [1, 2]}
    final_tpm = {"SRX1": [10.0, 20.0], "SRX2": [0.0, 0.0]}

    msc.write_matrices(gene_ids, final_counts, final_tpm, outdir=str(tmp_path))

    counts_lines = (tmp_path / "counts.csv").read_text().splitlines()
    assert counts_lines[0] == "GeneID,SRX1,SRX2"
    assert counts_lines[1] == "geneA,5,1"
    assert counts_lines[2] == "geneB,15,2"

    tpm_lines = (tmp_path / "tpm.csv").read_text().splitlines()
    assert tpm_lines[1] == "geneA,10.000000,0.000000"

    log_tpm_lines = (tmp_path / "log_tpm.csv").read_text().splitlines()
    # log2(10 + 1) = log2(11) ~= 3.459432
    assert log_tpm_lines[1].startswith("geneA,3.459")
    # log2(0 + 1) = 0
    assert log_tpm_lines[1].endswith(",0.000000")


def test_main_end_to_end(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    make_quant_dir(tmp_path, "SRX1_SRR1_quant", num_reads=[5, 15], tpm=[10.0, 20.0])
    (tmp_path / "passed.txt").write_text("SRX1_SRR1\n")

    rc = msc.main(["--passed-samples-file", "passed.txt"])

    assert rc is None or rc == 0
    assert (tmp_path / "tpm.csv").exists()
    assert (tmp_path / "counts.csv").read_text().splitlines()[1] == "geneA,5"
