import pandas as pd

import detect_strain_groups as dsg

# Fixtures below are trimmed reproductions of real NCBI API responses captured while
# investigating the UWC1-mislabeled-as-KT2440 case, not synthetic data.

UWC1_ALIAS = {
    "alias": "UWC1",
    "canonical_strain": "UWC1",
    "min_genome_size": 1000000,
    "ref_accession_override": None,
}

# https://api.ncbi.nlm.nih.gov/datasets/v2/genome/taxon/Pseudomonas putida UWC1/dataset_report
# -- every result under this exact name is a small standalone plasmid, not a genome.
UWC1_TAXON_REPORT_ALL_PLASMIDS = {
    "reports": [
        {
            "accession": "GCA_982345545.1",
            "source_database": "SOURCE_DATABASE_GENBANK",
            "assembly_info": {"atypical": {"is_atypical": True, "warnings": ["genome length too small"]}},
            "assembly_stats": {"total_sequence_length": "587656"},
        },
        {
            "accession": "GCA_982345415.1",
            "source_database": "SOURCE_DATABASE_GENBANK",
            "assembly_info": {"atypical": {"is_atypical": True, "warnings": ["genome length too small"]}},
            "assembly_stats": {"total_sequence_length": "525650"},
        },
    ]
}

# https://api.ncbi.nlm.nih.gov/datasets/v2/genome/taxon/Pseudomonas putida mt-2/dataset_report
# -- organism-name search finds nothing at all for mt-2 (it's filed under the bare
# species name with strain as a separate attribute, not in the organism name string).
MT2_TAXON_REPORT_EMPTY: dict = {}

# eutils esummary db=assembly for mt-2's two real RefSeq assemblies (uids 19208841,
# 16581741), trimmed to the fields pick_best_assembly_from_esummary reads.
MT2_ESUMMARY = {
    "result": {
        "uids": ["19208841", "16581741"],
        "19208841": {
            "assemblyaccession": "GCF_032681205.1",
            "assemblystatus": "Complete Genome",
            "biosource": {"infraspecieslist": [{"sub_type": "strain", "sub_value": "mt-2"}]},
            "meta": ' <Stats> <Stat category="total_length" sequence_tag="all">6183439</Stat> </Stats> ',
        },
        "16581741": {
            "assemblyaccession": "GCF_900183025.1",
            "assemblystatus": "Chromosome",
            "biosource": {"infraspecieslist": [{"sub_type": "strain", "sub_value": "mt-2"}]},
            "meta": ' <Stats> <Stat category="total_length" sequence_tag="all">6313543</Stat> </Stats> ',
        },
    }
}


def test_detect_strain_for_row_matches_alias_in_free_text():
    row = {
        "sample_title": "UWC1-ICEclc mfsR mutant at exponential 1",
        "sample_description": "P. putida UWC1 carrying mfsR-deficient ICEclc at exponential phase, replicate 1",
    }

    detected, evidence = dsg.detect_strain_for_row(row, default_strain="KT2440", aliases=[UWC1_ALIAS])

    assert detected == "UWC1"
    assert "UWC1" in evidence


def test_detect_strain_for_row_ignores_replicate_labels_like_f1_h2():
    # Real false-positive case found during investigation: a generic regex matched "F1"/
    # "H2" replicate labels as strain codes. The curated-alias approach must not do this
    # since neither "F1" nor "H2" is a configured alias.
    row = {
        "sample_title": "tc cells from UWC1-ICEclc at stationary F1",
        "sample_description": "tc cells from P. putida UWC1 carrying wild-type ICEclc at stationary phase collected by FACS, replicate 1",
    }

    detected, evidence = dsg.detect_strain_for_row(row, default_strain="KT2440", aliases=[UWC1_ALIAS])

    assert detected == "UWC1"


def test_detect_strain_for_row_defaults_when_no_alias_matches():
    row = {"sample_title": "Pseudomonas putida KT2440, early stationary phase, wild-type, rep. 1"}

    detected, evidence = dsg.detect_strain_for_row(row, default_strain="KT2440", aliases=[UWC1_ALIAS])

    assert detected == "KT2440"
    assert "default" in evidence


def test_build_strain_groups_labels_each_row():
    samplesheet_df = pd.DataFrame(
        {
            "id": ["DRX1_DRR1", "SRX1_SRR1"],
            "sample_title": ["UWC1-ICEclc mfsR mutant", "Pseudomonas putida KT2440"],
            "sample_description": ["P. putida UWC1 carrying...", ""],
            "experiment_title": ["", ""],
            "study_title": ["", ""],
            "sample_alias": ["", ""],
        }
    )

    result = dsg.build_strain_groups(samplesheet_df, default_strain="KT2440", aliases=[UWC1_ALIAS])

    assert list(result["detected_strain"]) == ["UWC1", "KT2440"]


def test_pick_best_assembly_rejects_all_atypical_plasmids():
    # Reproduces the real UWC1 case: every result is atypical/too-small, so nothing
    # should be picked -- forcing the resolver on to its esearch/esummary fallback.
    result = dsg.pick_best_assembly(UWC1_TAXON_REPORT_ALL_PLASMIDS, min_genome_size=1_000_000)

    assert result is None


def test_pick_best_assembly_returns_none_for_empty_report():
    # Reproduces the real mt-2 case: organism-name taxon search finds nothing at all.
    result = dsg.pick_best_assembly(MT2_TAXON_REPORT_EMPTY, min_genome_size=1_000_000)

    assert result is None


def test_pick_best_assembly_prefers_refseq_and_largest():
    report = {
        "reports": [
            {
                "accession": "GCA_000001.1",
                "source_database": "SOURCE_DATABASE_GENBANK",
                "assembly_info": {"atypical": {"is_atypical": False}},
                "assembly_stats": {"total_sequence_length": "6200000"},
            },
            {
                "accession": "GCF_000002.1",
                "source_database": "SOURCE_DATABASE_REFSEQ",
                "assembly_info": {"atypical": {"is_atypical": False}},
                "assembly_stats": {"total_sequence_length": "6100000"},
            },
        ]
    }

    result = dsg.pick_best_assembly(report, min_genome_size=1_000_000)

    assert result["accession"] == "GCF_000002.1"


def test_pick_best_assembly_from_esummary_finds_mt2_by_infraspecific_strain():
    # This is the real fallback path: mt-2 isn't findable via organism-name search, but
    # esearch/esummary against the assembly database finds it via the infraspecific
    # strain attribute.
    result = dsg.pick_best_assembly_from_esummary(MT2_ESUMMARY, strain="mt-2", min_genome_size=1_000_000)

    assert result["accession"] == "GCF_032681205.1"


def test_pick_best_assembly_from_esummary_prefers_complete_genome_over_larger_size():
    # GCF_900183025.1 is larger (6.31Mb vs 6.18Mb) but only "Chromosome"-level, while
    # GCF_032681205.1 is a full "Complete Genome" -- assembly completeness must win over
    # raw size, confirmed against the real esummary data for both.
    result = dsg.pick_best_assembly_from_esummary(MT2_ESUMMARY, strain="mt-2", min_genome_size=1_000_000)

    assert result["accession"] == "GCF_032681205.1"


def test_resolve_reference_for_strain_uses_manual_override():
    alias_entry = {"ref_accession_override": "GCF_032681205.1", "min_genome_size": 1000000}

    result = dsg.resolve_reference_for_strain("Pseudomonas putida", "UWC1", alias_entry)

    assert result == {
        "strain": "UWC1",
        "ref_accession": "GCF_032681205.1",
        "resolution_method": "manual_override",
        "status": "resolved",
    }


def test_resolve_reference_for_strain_rejects_malformed_override():
    alias_entry = {"ref_accession_override": "not-an-accession"}

    result = dsg.resolve_reference_for_strain("Pseudomonas putida", "UWC1", alias_entry)

    assert result["status"] == "unresolved"
    assert result["resolution_method"] == "invalid_override"


def test_strain_slug_sanitizes_for_filenames():
    assert dsg.strain_slug("UWC1") == "UWC1"
    assert dsg.strain_slug("mt-2 variant") == "mt-2_variant"


def test_main_end_to_end(tmp_path, monkeypatch, capsys):
    outdir = tmp_path / "run"
    (outdir / "samplesheet").mkdir(parents=True)
    pd.DataFrame(
        {
            "id": ["DRX1_DRR1", "SRX1_SRR1"],
            "run_accession": ["DRR1", "SRR1"],
            "fastq_1": ["seqFiles/fastq/DRX1_DRR1_1.fastq.gz", "seqFiles/fastq/SRX1_SRR1_1.fastq.gz"],
            "fastq_2": ["", ""],
            "sample_title": ["UWC1-ICEclc mfsR mutant", "Pseudomonas putida KT2440"],
            "sample_description": ["P. putida UWC1 carrying...", ""],
            "experiment_title": ["", ""],
            "study_title": ["", ""],
            "sample_alias": ["", ""],
        }
    ).to_csv(outdir / "samplesheet" / "samplesheet_download.csv", index=False)

    alias_config = tmp_path / "strain_aliases.json"
    alias_config.write_text(
        '{"Pseudomonas putida": [{"alias": "UWC1", "canonical_strain": "UWC1", '
        '"min_genome_size": 1000000, "ref_accession_override": "GCF_032681205.1"}]}'
    )

    dsg.main(
        [
            "--outdir", str(outdir),
            "--organism", "Pseudomonas putida",
            "--strain", "KT2440",
            "--alias-config", str(alias_config),
        ]
    )

    captured = capsys.readouterr()
    assert "STRAIN_GROUP=UWC1|GCF_032681205.1|manual_override|" in captured.out

    strain_groups = pd.read_csv(outdir / "metadata" / "strain_groups.csv")
    assert dict(zip(strain_groups["id"], strain_groups["detected_strain"])) == {
        "DRX1_DRR1": "UWC1",
        "SRX1_SRR1": "KT2440",
    }

    reference_map = pd.read_csv(outdir / "metadata" / "strain_reference_map.csv")
    assert reference_map.iloc[0]["strain"] == "UWC1"
    assert reference_map.iloc[0]["ref_accession"] == "GCF_032681205.1"

    exclude_ids = (outdir / "metadata" / "exclude_ids_primary.txt").read_text().splitlines()
    assert exclude_ids == ["DRX1_DRR1"]

    override_df = pd.read_csv(outdir / "metadata" / "samplesheet_by_strain" / "UWC1.csv")
    assert list(override_df["id"]) == ["DRX1_DRR1"]
