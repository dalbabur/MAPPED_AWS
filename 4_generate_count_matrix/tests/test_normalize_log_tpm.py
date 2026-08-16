import pandas as pd
import pytest

import normalize_log_tpm as nlt


def test_normalize_subtracts_row_mean():
    df = pd.DataFrame({"GeneID": ["g1"], "s1": [1.0], "s2": [3.0]})

    out = nlt.normalize(df)

    # row mean = 2.0 -> [1-2, 3-2] = [-1, 1]
    assert out.iloc[0]["s1"] == pytest.approx(-1.0)
    assert out.iloc[0]["s2"] == pytest.approx(1.0)


def test_normalize_drops_rows_that_become_entirely_zero():
    # g1 has zero variance across samples -> centered row is all zero -> dropped.
    # g2 has real variance -> kept.
    df = pd.DataFrame({"GeneID": ["g1", "g2"], "s1": [5.0, 1.0], "s2": [5.0, 3.0]})

    out = nlt.normalize(df)

    assert list(out["GeneID"]) == ["g2"]


def test_normalize_single_sample_drops_every_gene():
    # A single sample's deviation from its own mean is always exactly zero -- this is
    # the specific edge case DATA_VALIDATION's own docstring calls out as legitimate,
    # not an error, when there's only one sample in a run.
    df = pd.DataFrame({"GeneID": ["g1", "g2"], "s1": [10.0, 20.0]})

    out = nlt.normalize(df)

    assert len(out) == 0
    assert list(out.columns) == ["GeneID", "s1"]


def test_main_end_to_end(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    pd.DataFrame({"GeneID": ["g1", "g2"], "s1": [1.0, 5.0], "s2": [3.0, 5.0]}).to_csv(
        tmp_path / "log_tpm.csv", index=False
    )

    nlt.main(["--log-tpm", "log_tpm.csv", "--output", "log_tpm_norm.csv"])

    out = pd.read_csv(tmp_path / "log_tpm_norm.csv")
    assert list(out["GeneID"]) == ["g1"]
