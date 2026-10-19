"""The diagnosis contract (configs/schemas/diagnosis.schema.json + configs/diagnosis_rules.json): the golden documents
hold, the catalogue is consistent, and each cross-check names the violation it is for."""

import copy

import pytest

from bossman.services import diagnosis_contract as C

EXAMPLES = C.examples()


def test_there_are_golden_documents_for_both_platforms_and_the_gap_case():
    assert {"windows-logon-right", "windows-dependency", "linux-203-exec", "unknown-gap"} <= set(EXAMPLES)
    assert {d["platform"] for d in EXAMPLES.values()} == {"windows", "linux"}


@pytest.mark.parametrize("name", sorted(EXAMPLES))
def test_every_golden_document_holds(name):
    assert C.violations(EXAMPLES[name]) == []


def test_the_catalogue_is_consistent():
    assert C.catalogue_violations() == []


def test_every_remedy_kind_a_rule_offers_exists_in_the_schema():
    kinds = set(C.remedy_kinds())
    for rid, rule in C.rules().items():
        assert set(rule["remedy_kinds"]) <= kinds, rid


def test_windows_rules_one_to_seven_and_the_linux_causes_are_covered():
    win = {r for r, v in C.rules().items() if "windows" in v["platforms"]}
    lin = {r for r, v in C.rules().items() if "linux" in v["platforms"]}
    assert {"svc.dependency_failed", "svc.image_missing", "svc.logon_failed", "svc.logon_right_missing",
            "svc.access_denied", "svc.timeout", "svc.disabled", "svc.exits_immediately", "svc.unexplained"} <= win
    # the causes package_e2e_bossman.SHIPPED_CAUSES classifies, under their shared names
    assert {"svc.dependency_failed", "svc.disabled", "svc.account_missing", "svc.crash", "svc.image_missing",
            "svc.access_denied", "svc.config_invalid", "svc.not_initialized", "svc.network_unavailable",
            "svc.peer_unreachable", "svc.condition_failed", "svc.container_limit", "svc.device_missing",
            "svc.unexplained"} <= lin


def _doc():
    return copy.deepcopy(EXAMPLES["windows-logon-right"])


def test_a_finding_without_evidence_is_not_a_finding():
    d = _doc()
    d["findings"][0]["evidence_ids"] = []
    assert any("evidence_ids" in v for v in C.violations(d))


def test_a_finding_citing_unknown_evidence_is_named():
    d = _doc()
    d["findings"][0]["evidence_ids"].append("evt:System:7000:1")
    assert any("not in the diagnosis: evt:System:7000:1" in v for v in C.violations(d))


def test_unknown_needs_its_gap():
    d = copy.deepcopy(EXAMPLES["unknown-gap"])
    d["findings"][0]["gap"] = None
    assert C.violations(d)


def test_a_stopped_target_without_finding_violates_excluded_middle():
    d = _doc()
    d["findings"] = []
    assert any("svc.unexplained" in v for v in C.violations(d))


def test_certainty_above_the_rule_maximum_is_refused():
    d = copy.deepcopy(EXAMPLES["unknown-gap"])
    d["findings"][0]["certainty"] = "Proven"
    d["findings"][0]["gap"] = None
    assert any("exceeds the rule's maximum Unknown" in v for v in C.violations(d))


def test_a_precedent_alone_is_no_cause():
    d = _doc()
    d["findings"][0]["evidence_ids"] = ["evt:System:7045:20420"]
    assert any("correlation, not a cause" in v for v in C.violations(d))


def test_a_rule_of_another_platform_is_named():
    d = copy.deepcopy(EXAMPLES["linux-203-exec"])
    d["findings"][0]["rule_id"] = "svc.logon_right_missing"
    assert any("does not apply to platform linux" in v for v in C.violations(d))


def test_the_timeline_lists_exactly_the_timed_evidence_in_order():
    d = _doc()
    d["timeline"].reverse()
    assert any("time order" in v for v in C.violations(d))
    d = _doc()
    d["timeline"].pop()
    assert any("exactly the evidence" in v for v in C.violations(d))


def test_a_remedy_kind_the_rule_does_not_offer_is_named():
    d = _doc()
    d["findings"][0]["remedy"]["target"]["kind"] = "package"
    assert any("not one the rule offers" in v for v in C.violations(d))


def test_an_unknown_rule_is_named():
    d = _doc()
    d["findings"][0]["rule_id"] = "svc.guessed"
    assert any("not in configs/diagnosis_rules.json" in v for v in C.violations(d))
