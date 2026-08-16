import json

import parse_qc as pq


def fastqc_entry(overall="pass"):
    """A single sample's FastQC metric block, all three TARGET_METRICS set to `overall`."""
    return {metric: overall for metric in pq.TARGET_METRICS}


def test_base_sample_name_and_experiment_id():
    assert pq.base_sample_name("SRX1_SRR1_val_1") == "SRX1_SRR1"
    assert pq.experiment_id("SRX1_SRR1") == "SRX1"


def test_extract_fastqc_data_present():
    data = {"report_saved_raw_data": {"multiqc_fastqc": {"s1": {}}}}
    assert pq.extract_fastqc_data(data) == {"s1": {}}


def test_extract_fastqc_data_missing_returns_none():
    assert pq.extract_fastqc_data({}) is None
    assert pq.extract_fastqc_data({"report_saved_raw_data": {}}) is None


def test_evaluate_samples_all_pass():
    fastqc_data = {"SRX1_SRR1": fastqc_entry("pass")}

    qc_results, experiment_status, experiment_samples = pq.evaluate_samples(fastqc_data)

    assert experiment_status == {"SRX1": True}
    assert experiment_samples == {"SRX1": {"SRX1_SRR1"}}
    assert qc_results[0]["overall_status"] == "PASS"


def test_evaluate_samples_one_failed_metric_fails_the_sample():
    fastqc_data = {"SRX1_SRR1": {**fastqc_entry("pass"), "per_base_n_content": "fail"}}

    qc_results, experiment_status, _ = pq.evaluate_samples(fastqc_data)

    assert experiment_status["SRX1"] is False
    assert qc_results[0]["overall_status"] == "FAIL"


def test_evaluate_samples_one_bad_run_fails_the_whole_experiment():
    # Two runs of the same experiment; one run fails -> the *experiment* is failed,
    # since MERGE_COUNTS/MERGE_COUNTS_FEATURECOUNTS merge runs together per experiment
    # and a bad run would otherwise silently contaminate the merged result.
    fastqc_data = {
        "SRX1_SRR1": fastqc_entry("pass"),
        "SRX1_SRR2": {**fastqc_entry("pass"), "per_base_n_content": "fail"},
    }

    _, experiment_status, experiment_samples = pq.evaluate_samples(fastqc_data)

    assert experiment_status["SRX1"] is False
    assert experiment_samples["SRX1"] == {"SRX1_SRR1", "SRX1_SRR2"}


def test_passed_sample_ids_only_includes_passed_experiments():
    experiment_status = {"SRX1": True, "SRX2": False}
    experiment_samples = {"SRX1": {"SRX1_SRR1"}, "SRX2": {"SRX2_SRR1"}}

    assert pq.passed_sample_ids(experiment_status, experiment_samples) == {"SRX1_SRR1"}


def test_failed_samples_detail_lists_failed_metrics():
    fastqc_data = {"SRX1_SRR1": {**fastqc_entry("pass"), "per_base_n_content": "fail"}}
    experiment_status = {"SRX1": False}

    detail = pq.failed_samples_detail(fastqc_data, experiment_status)

    assert detail == [("SRX1_SRR1", ["per_base_n_content"])]


def test_main_writes_passed_samples_for_all_pass(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    multiqc_data = {
        "report_saved_raw_data": {
            "multiqc_fastqc": {
                "SRX1_SRR1": fastqc_entry("pass"),
                "SRX2_SRR1": {**fastqc_entry("pass"), "per_base_n_content": "fail"},
            }
        }
    }
    (tmp_path / "multiqc_data.json").write_text(json.dumps(multiqc_data))

    rc = pq.main(["--multiqc-json", "multiqc_data.json"])

    assert rc == 0
    passed = (tmp_path / "passed_samples.txt").read_text().splitlines()
    assert passed == ["SRX1_SRR1"]
    assert (tmp_path / "qc_summary.csv").exists()
    summary_txt = (tmp_path / "qc_summary.txt").read_text()
    assert "Experiments passed: 1" in summary_txt
    assert "Experiments failed: 1" in summary_txt


def test_main_no_fastqc_data_writes_empty_outputs_not_error(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    (tmp_path / "multiqc_data.json").write_text(json.dumps({}))

    rc = pq.main(["--multiqc-json", "multiqc_data.json"])

    assert rc == 0
    assert (tmp_path / "passed_samples.txt").read_text() == ""


def test_main_malformed_json_writes_empty_outputs_not_crash(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    (tmp_path / "multiqc_data.json").write_text("{not valid json")

    rc = pq.main(["--multiqc-json", "multiqc_data.json"])

    assert rc == 0
    assert (tmp_path / "passed_samples.txt").exists()
    assert "Error processing MultiQC data" in (tmp_path / "qc_summary.txt").read_text()
