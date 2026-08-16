import pandas as pd

import filter_low_expression_samples as fles


def test_find_low_expression_samples_flags_over_threshold():
    counts_df = pd.DataFrame(
        {
            "good": [1, 2, 3, 4],  # 0% zero
            "bad": [0, 0, 0, 4],  # 75% zero
            "borderline": [0, 0, 3, 4],  # 50% zero, not > threshold
        },
        index=["g1", "g2", "g3", "g4"],
    )

    to_remove = fles.find_low_expression_samples(counts_df, threshold=0.5)

    assert to_remove == ["bad"]


def test_filter_matrices_drops_flagged_columns():
    tpm_df = pd.DataFrame({"keep": [1.0], "drop": [2.0]}, index=["g1"])
    log_tpm_df = pd.DataFrame({"keep": [0.1], "drop": [0.2]}, index=["g1"])
    counts_df = pd.DataFrame({"keep": [1], "drop": [2]}, index=["g1"])

    tpm_f, log_tpm_f, counts_f = fles.filter_matrices(tpm_df, log_tpm_df, counts_df, ["drop"])

    assert list(tpm_f.columns) == ["keep"]
    assert list(log_tpm_f.columns) == ["keep"]
    assert list(counts_f.columns) == ["keep"]


def test_filter_matrices_no_removal_returns_unchanged():
    tpm_df = pd.DataFrame({"a": [1.0]}, index=["g1"])
    log_tpm_df = pd.DataFrame({"a": [0.1]}, index=["g1"])
    counts_df = pd.DataFrame({"a": [1]}, index=["g1"])

    tpm_f, log_tpm_f, counts_f = fles.filter_matrices(tpm_df, log_tpm_df, counts_df, [])

    assert tpm_f is tpm_df
    assert log_tpm_f is log_tpm_df
    assert counts_f is counts_df


def test_filter_samplesheet_drops_rows_by_id():
    df = pd.DataFrame({"id": ["SRX1", "SRX2", "SRX3"], "other": [1, 2, 3]})

    filtered = fles.filter_samplesheet(df, ["SRX2"])

    assert sorted(filtered["id"]) == ["SRX1", "SRX3"]


def test_read_samplesheet_robust_reads_well_formed_csv(tmp_path):
    f = tmp_path / "samplesheet.csv"
    f.write_text("id,other\nSRX1,1\nSRX2,2\n")

    df = fles.read_samplesheet_robust(str(f))

    assert list(df["id"]) == ["SRX1", "SRX2"]


def test_read_samplesheet_robust_handles_malformed_quoting(tmp_path):
    # A stray unescaped quote mid-field is exactly the kind of thing ENA/NCBI metadata
    # can contain (free-text titles) -- the standard parser chokes on it, forcing the
    # manual-parse fallback.
    f = tmp_path / "samplesheet.csv"
    f.write_text('id,title,other\nSRX1,"a "bad" title",1\nSRX2,"a fine title",2\n')

    df = fles.read_samplesheet_robust(str(f))

    assert len(df) == 2
    assert list(df["id"]) == ["SRX1", "SRX2"]


def test_main_end_to_end(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    pd.DataFrame({"good": [1.0, 2.0], "bad": [0.0, 0.0]}, index=["g1", "g2"]).to_csv(tmp_path / "tpm.csv")
    pd.DataFrame({"good": [0.1, 0.2], "bad": [0.0, 0.0]}, index=["g1", "g2"]).to_csv(tmp_path / "log_tpm.csv")
    pd.DataFrame({"good": [1, 2], "bad": [0, 0]}, index=["g1", "g2"]).to_csv(tmp_path / "counts.csv")
    (tmp_path / "samplesheet.csv").write_text("id,other\ngood,1\nbad,2\n")

    fles.main(
        [
            "--tpm", "tpm.csv",
            "--log-tpm", "log_tpm.csv",
            "--counts", "counts.csv",
            "--samplesheet", "samplesheet.csv",
        ]
    )

    tpm_out = pd.read_csv(tmp_path / "tpm.csv", index_col=0)
    assert list(tpm_out.columns) == ["good"]
    samplesheet_out = pd.read_csv(tmp_path / "samplesheet.csv")
    assert list(samplesheet_out["id"]) == ["good"]
