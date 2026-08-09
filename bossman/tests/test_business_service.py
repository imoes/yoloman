"""Roll-up logic tests (services/business_service.py)."""

from bossman.services.business_service import rollup


def test_all_is_worst_of():
    assert rollup(["OK", "OK", "OK"], "all") == "OK"
    assert rollup(["OK", "WARN", "OK"], "all") == "WARN"
    assert rollup(["OK", "WARN", "CRIT"], "all") == "CRIT"
    assert rollup(["OK", "UNKNOWN"], "all") == "UNKNOWN"
    # CRIT outranks UNKNOWN
    assert rollup(["UNKNOWN", "CRIT"], "all") == "CRIT"


def test_any_is_best_of():
    assert rollup(["CRIT", "CRIT", "OK"], "any") == "OK"   # redundancy: one healthy → OK
    assert rollup(["CRIT", "WARN"], "any") == "WARN"
    assert rollup(["CRIT", "CRIT"], "any") == "CRIT"       # all down → CRIT
    assert rollup(["WARN", "OK"], "any") == "OK"


def test_empty_is_unknown():
    assert rollup([], "all") == "UNKNOWN"
    assert rollup([], "any") == "UNKNOWN"
