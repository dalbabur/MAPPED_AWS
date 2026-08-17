import filter_samplesheet as fs


def test_strip_quotes_removes_when_present():
    assert fs.strip_quotes('"SRX1"') == "SRX1"


def test_strip_quotes_noop_when_absent():
    assert fs.strip_quotes("SRX1") == "SRX1"


def test_strip_quotes_handles_empty_and_none():
    assert fs.strip_quotes("") == ""
    assert fs.strip_quotes(None) is None


def test_find_id_column_matches_unquoted_header():
    assert fs.find_id_column(["sample", "id", "other"]) == "id"


def test_find_id_column_matches_quoted_header():
    assert fs.find_id_column(["sample", '"id"', "other"]) == '"id"'


def test_find_id_column_none_if_absent():
    assert fs.find_id_column(["sample", "other"]) is None


def test_filter_rows_matches_unquoted_values():
    # Regression test: today's real samplesheet_download.csv has unquoted id values.
    # The original bash always wrapped the comparison value in literal quotes, so it
    # matched zero rows against data like this -- silently, since errorStrategy 'ignore'
    # hid the failure. See git history for the bug this replaced.
    rows = [
        {"id": "SRX1", "other": "a"},
        {"id": "SRX2", "other": "b"},
    ]
    result = fs.filter_rows(rows, "id", ["SRX1"])
    assert result == [{"id": "SRX1", "other": "a"}]


def test_filter_rows_matches_quoted_values():
    rows = [
        {"id": '"SRX1"', "other": "a"},
        {"id": '"SRX2"', "other": "b"},
    ]
    result = fs.filter_rows(rows, "id", ["SRX1"])
    assert result == [{"id": '"SRX1"', "other": "a"}]


def test_filter_rows_preserves_passed_id_order_not_csv_order():
    rows = [
        {"id": "SRX2", "other": "b"},
        {"id": "SRX1", "other": "a"},
    ]
    result = fs.filter_rows(rows, "id", ["SRX1", "SRX2"])
    assert [r["id"] for r in result] == ["SRX1", "SRX2"]


def test_filter_rows_dedupes_identical_rows():
    rows = [
        {"id": "SRX1", "other": "a"},
        {"id": "SRX1", "other": "a"},
    ]
    result = fs.filter_rows(rows, "id", ["SRX1"])
    assert result == [{"id": "SRX1", "other": "a"}]


def test_filter_rows_no_match_returns_empty():
    rows = [{"id": "SRX1", "other": "a"}]
    assert fs.filter_rows(rows, "id", ["SRX_DOES_NOT_EXIST"]) == []


def test_main_end_to_end_happy_path(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    (tmp_path / "samplesheet_download.csv").write_text(
        "sample,id,other\nSRX1,SRX1,x\nSRX2,SRX2,y\n"
    )
    (tmp_path / "passed_samples.txt").write_text("SRX1\n")

    rc = fs.main(["--samplesheet", "samplesheet_download.csv", "--passed-samples-file", "passed_samples.txt"])

    assert rc == 0
    out = (tmp_path / "samplesheet.csv").read_text().splitlines()
    assert out == ["sample,id,other", "SRX1,SRX1,x"]


def test_main_no_passed_samples_writes_header_only(tmp_path, monkeypatch, capsys):
    monkeypatch.chdir(tmp_path)
    (tmp_path / "samplesheet_download.csv").write_text("sample,id,other\nSRX1,SRX1,x\n")
    (tmp_path / "passed_samples.txt").write_text("")

    rc = fs.main(["--samplesheet", "samplesheet_download.csv", "--passed-samples-file", "passed_samples.txt"])

    assert rc == 0
    out = (tmp_path / "samplesheet.csv").read_text().splitlines()
    assert out == ["sample,id,other"]
    assert "WARNING: No samples passed QC filters!" in capsys.readouterr().out


def test_main_missing_id_column_returns_1(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    (tmp_path / "samplesheet_download.csv").write_text("sample,other\nSRX1,x\n")
    (tmp_path / "passed_samples.txt").write_text("SRX1\n")

    rc = fs.main(["--samplesheet", "samplesheet_download.csv", "--passed-samples-file", "passed_samples.txt"])

    assert rc == 1


def test_main_ignores_blank_lines_in_samplesheet(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    (tmp_path / "samplesheet_download.csv").write_text("sample,id,other\n\nSRX1,SRX1,x\n   \nSRX2,SRX2,y\n")
    (tmp_path / "passed_samples.txt").write_text("SRX1\nSRX2\n")

    rc = fs.main(["--samplesheet", "samplesheet_download.csv", "--passed-samples-file", "passed_samples.txt"])

    assert rc == 0
    out = (tmp_path / "samplesheet.csv").read_text().splitlines()
    assert out == ["sample,id,other", "SRX1,SRX1,x", "SRX2,SRX2,y"]
