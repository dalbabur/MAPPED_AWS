import pandas as pd

import detect_gene_dropouts as dgd


def test_find_dropouts_flags_typically_expressed_gene_dropping_to_zero():
    samples = [f"s{i}" for i in range(1, 11)]
    counts_df = pd.DataFrame(
        {
            # typically expressed (median 100, active in 8/10 samples -- exactly at the
            # 0.8 active-fraction bar) -- s9, s10 are dropouts
            "g1": [100, 100, 100, 100, 100, 100, 100, 100, 0, 1],
            # never well-expressed anywhere (median 5) -- not screened
            "g2": [5, 4, 6, 5, 4, 6, 5, 4, 6, 5],
            # typically expressed but never drops to near-zero -- no dropout events
            "g3": [50] * 10,
        },
        index=samples,
    ).T

    events = dgd.find_dropouts(counts_df, min_typical_count=20, min_active_fraction=0.8, dropout_max_count=2)

    assert sorted(events["sample"]) == ["s10", "s9"]
    assert set(events["gene"]) == {"g1"}


def test_find_dropouts_no_events_returns_empty_dataframe():
    counts_df = pd.DataFrame(
        {"s1": [100, 5], "s2": [95, 4], "s3": [105, 6]},
        index=["g1", "g2"],
    )

    events = dgd.find_dropouts(counts_df, min_typical_count=20, min_active_fraction=0.8, dropout_max_count=2)

    assert events.empty
    assert list(events.columns) == ["gene", "sample", "count", "compendium_median_count"]


def test_find_dropouts_ignores_condition_specific_gene():
    # A gene that's simply off in most samples (not a knockout signature) should never
    # clear the active-fraction bar, regardless of how low its counts get elsewhere.
    counts_df = pd.DataFrame(
        {"s1": [100, 0], "s2": [95, 0], "s3": [105, 0], "s4": [98, 40]},
        index=["g1", "condition_specific"],
    )

    events = dgd.find_dropouts(counts_df, min_typical_count=20, min_active_fraction=0.8, dropout_max_count=2)

    assert "condition_specific" not in set(events["gene"])


def test_main_end_to_end(tmp_path, monkeypatch, capsys):
    monkeypatch.chdir(tmp_path)
    samples = [f"s{i}" for i in range(1, 11)]
    pd.DataFrame(
        {
            "g1": [100, 100, 100, 100, 100, 100, 100, 100, 0, 1],
            "g2": [5, 4, 6, 5, 4, 6, 5, 4, 6, 5],
            "g3": [50] * 10,
        },
        index=samples,
    ).T.to_csv(tmp_path / "counts.csv")

    dgd.main(["--counts", "counts.csv", "--out", "events.csv"])

    events_out = pd.read_csv(tmp_path / "events.csv")
    assert sorted(events_out["sample"]) == ["s10", "s9"]
