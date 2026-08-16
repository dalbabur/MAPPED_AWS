import pandas as pd
import pytest

import data_validation as dv


def test_merge_duplicate_download_rows_singleton_passes_through():
    df = pd.DataFrame({"id": ["SRX1_SRR1"], "run_accession": ["SRR1"], "other": ["x"]})

    out = dv.merge_duplicate_download_rows(df)

    assert list(out["id"]) == ["SRX1"]
    assert "experiment_id" not in out.columns


def test_merge_duplicate_download_rows_multi_run_concats_and_overrides_id():
    df = pd.DataFrame(
        {
            "id": ["SRX1_SRR1", "SRX1_SRR2"],
            "run_accession": ["SRR1", "SRR2"],
            "other": ["x", "y"],
        }
    )

    out = dv.merge_duplicate_download_rows(df)

    assert len(out) == 1
    row = out.iloc[0]
    # 'id' becomes the derived experiment ID itself, NOT a semicolon join, even though
    # 'id' is in CONCAT_COLUMNS -- this is the one deliberate divergence from
    # merge_duplicate_samplesheet_rows.
    assert row["id"] == "SRX1"
    assert row["run_accession"] == "SRR1;SRR2"
    # non-concat columns take the first non-null value
    assert row["other"] == "x"


def test_merge_duplicate_download_rows_missing_id_column_noop():
    df = pd.DataFrame({"other": ["x"]})

    out = dv.merge_duplicate_download_rows(df)

    assert out is df


def test_find_sample_id_column_prefers_sample():
    df = pd.DataFrame({"sample": ["a"], "id": ["b"]})
    assert dv.find_sample_id_column(df) == "sample"


def test_find_sample_id_column_falls_back_to_alternates():
    df = pd.DataFrame({"experiment_accession": ["a"]})
    assert dv.find_sample_id_column(df) == "experiment_accession"


def test_find_sample_id_column_none_if_nothing_matches():
    df = pd.DataFrame({"unrelated": ["a"]})
    assert dv.find_sample_id_column(df) is None


def test_merge_duplicate_samplesheet_rows_does_not_override_group_key():
    # Unlike merge_duplicate_download_rows, the group key here is an *existing* shared
    # value, not something derived -- so it's never overridden, it's just whatever the
    # group already agreed on.
    df = pd.DataFrame(
        {
            "sample": ["SRX1", "SRX1"],
            "run_accession": ["SRR1", "SRR2"],
            "other": ["x", "y"],
        }
    )

    out = dv.merge_duplicate_samplesheet_rows(df, "sample")

    assert len(out) == 1
    assert out.iloc[0]["sample"] == "SRX1"
    assert out.iloc[0]["run_accession"] == "SRR1;SRR2"


def test_reconcile_samplesheet_with_matrices_filters_renames_and_reorders():
    df = pd.DataFrame({"experiment_accession": ["SRX1", "SRX2"], "other": [1, 2]})

    out = dv.reconcile_samplesheet_with_matrices(df, "experiment_accession", expression_samples={"SRX1"})

    assert list(out["sample"]) == ["SRX1"]
    assert out.columns[0] == "sample"


def test_strip_gene_prefix_removes_when_present():
    df = pd.DataFrame({"s1": [1, 2]}, index=["gene-PP_RS00005", "gene-PP_RS00010"])

    out, changed = dv.strip_gene_prefix(df)

    assert changed is True
    assert list(out.index) == ["PP_RS00005", "PP_RS00010"]


def test_strip_gene_prefix_noop_when_absent():
    df = pd.DataFrame({"s1": [1]}, index=["PP_RS00005"])

    out, changed = dv.strip_gene_prefix(df)

    assert changed is False
    assert list(out.index) == ["PP_RS00005"]


def test_strip_gene_prefix_empty_matrix_is_not_an_error():
    df = pd.DataFrame({"s1": []})

    out, changed = dv.strip_gene_prefix(df)

    assert changed is False
    assert len(out) == 0


def test_validate_matrix_columns_consistent_passes_when_equal():
    cols = {"a.csv": ["s1", "s2"], "b.csv": ["s1", "s2"]}
    assert dv.validate_matrix_columns_consistent(cols) == ["s1", "s2"]


def test_validate_matrix_columns_consistent_raises_on_mismatch():
    cols = {"a.csv": ["s1", "s2"], "b.csv": ["s1"]}
    with pytest.raises(ValueError):
        dv.validate_matrix_columns_consistent(cols)


def test_main_end_to_end_matching_samples(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    for name in ("tpm.csv", "log_tpm.csv", "counts.csv", "log_tpm_norm.csv"):
        pd.DataFrame({"GeneID": ["gene-g1"], "SRX1": [1.0]}).set_index("GeneID").to_csv(tmp_path / name)
    pd.DataFrame({"sample": ["SRX1"], "other": [1]}).to_csv(tmp_path / "samplesheet.csv", index=False)
    pd.DataFrame({"id": ["SRX1_SRR1"], "other": [1]}).to_csv(tmp_path / "samplesheet_download_orig.csv", index=False)

    rc = dv.main(
        [
            "--samplesheet", "samplesheet.csv",
            "--tpm", "tpm.csv",
            "--log-tpm", "log_tpm.csv",
            "--counts", "counts.csv",
            "--log-tpm-norm", "log_tpm_norm.csv",
            "--samplesheet-download", "samplesheet_download_orig.csv",
        ]
    )

    assert rc == 0
    final_samplesheet = pd.read_csv(tmp_path / "samplesheet.csv")
    assert list(final_samplesheet["sample"]) == ["SRX1"]
    final_tpm = pd.read_csv(tmp_path / "tpm.csv", index_col=0)
    assert list(final_tpm.index) == ["g1"]  # 'gene-' prefix stripped
    final_download = pd.read_csv(tmp_path / "samplesheet_download.csv")
    assert list(final_download["id"]) == ["SRX1"]


def test_main_returns_nonzero_on_genuine_mismatch(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    for name in ("tpm.csv", "log_tpm.csv", "counts.csv", "log_tpm_norm.csv"):
        pd.DataFrame({"GeneID": ["g1"], "SRX1": [1.0]}).set_index("GeneID").to_csv(tmp_path / name)
    # Samplesheet references a sample that will never match the matrices' "SRX1" column,
    # even after filtering -- since none of the samplesheet rows survive, the final
    # samplesheet ends up with zero rows while the matrix still has one, which the
    # FINAL VERIFICATION step must catch rather than silently report success.
    pd.DataFrame({"sample": ["SRX_DOES_NOT_EXIST"], "other": [1]}).to_csv(tmp_path / "samplesheet.csv", index=False)

    rc = dv.main(
        [
            "--samplesheet", "samplesheet.csv",
            "--tpm", "tpm.csv",
            "--log-tpm", "log_tpm.csv",
            "--counts", "counts.csv",
            "--log-tpm-norm", "log_tpm_norm.csv",
        ]
    )

    assert rc == 1
