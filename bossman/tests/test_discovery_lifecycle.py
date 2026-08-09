"""The discovery lifecycle — classify() against Checkmk's QualifiedDiscovery semantics.

Every case here encodes a rule from cmk/checkengine/discovery/types.py:138. The one that
matters most is the identity/comparator split: a parameter edit must read as "changed",
never as a vanished-plus-new pair, or the discovery page reports churn every time someone
adjusts a threshold.
"""

from bossman.services.discovery_lifecycle import (
    DiscoverySettings,
    ServiceRecord,
    classify,
    records_from_proposals,
)


def _r(check, item="", params=None, labels=None):
    return ServiceRecord(check, item, params or {}, labels or {})


def test_new_and_vanished_are_symmetric():
    pre = [_r("df", "/"), _r("df", "/var")]
    cur = [_r("df", "/"), _r("lnx_if", "ens18")]
    t = classify(pre, cur)
    assert [r.id() for r in t.new] == [("lnx_if", "ens18")]
    assert [r.id() for r in t.vanished] == [("df", "/var")]
    assert [r.id() for r in t.unchanged] == [("df", "/")]
    assert t.changed == []


def test_identity_is_check_and_item_only():
    """A parameter change is the SAME service, changed — not new + vanished.

    This is the whole reason id() and comparator() are separate functions in Checkmk.
    """
    pre = [_r("df", "/", {"warn": 80})]
    cur = [_r("df", "/", {"warn": 90})]
    t = classify(pre, cur)
    assert t.new == [] and t.vanished == []
    assert len(t.changed) == 1
    previous, now = t.changed[0]
    assert previous.parameters["warn"] == 80 and now.parameters["warn"] == 90


def test_service_labels_are_half_the_comparator():
    """Checkmk's comparator() is (parameters, service_labels) — labels alone suffice."""
    pre = [_r("df", "/", {"warn": 80}, {"tier": "gold"})]
    cur = [_r("df", "/", {"warn": 80}, {"tier": "silver"})]
    t = classify(pre, cur)
    assert len(t.changed) == 1 and t.unchanged == []


def test_key_order_is_not_a_change():
    """Checkmk compares Mappings; dict insertion order must not fake a change."""
    pre = [_r("mysql", "inst", {"a": 1, "b": 2})]
    cur = [_r("mysql", "inst", {"b": 2, "a": 1})]
    t = classify(pre, cur)
    assert len(t.unchanged) == 1 and t.changed == []


def test_single_service_item_is_the_empty_string():
    """Our documented deviation: item="" where Checkmk has item=None."""
    t = classify([_r("uptime", "")], [_r("uptime", "")])
    assert len(t.unchanged) == 1
    # …and it is a different service from an item-carrying one of the same check.
    t2 = classify([_r("uptime", "")], [_r("uptime", "x")])
    assert len(t2.new) == 1 and len(t2.vanished) == 1


def test_empty_sides():
    assert classify([], []).counts() == {"new": 0, "unchanged": 0, "changed": 0, "vanished": 0}
    assert classify([], [_r("df", "/")]).counts()["new"] == 1
    assert classify([_r("df", "/")], []).counts()["vanished"] == 1


def test_duplicate_ids_collapse():
    """Checkmk's _deduplicate keeps one entry per id(); a duplicate must not double-count."""
    t = classify([], [_r("df", "/", {"warn": 1}), _r("df", "/", {"warn": 2})])
    assert len(t.new) == 1


# --- records_from_proposals -------------------------------------------------


class _Item:
    def __init__(self, item, params=None, service_labels=None):
        self.item = item
        self.params = params or {}
        self.service_labels = service_labels or {}


class _Proposal:
    def __init__(self, name, items, error=""):
        self.check_name = name
        self.items = items
        self.error = error


def test_proposals_become_one_record_per_item():
    recs = records_from_proposals([_Proposal("lnx_if", [_Item("ens18"), _Item("bond0")])])
    assert [r.id() for r in recs] == [("lnx_if", "ens18"), ("lnx_if", "bond0")]


def test_errored_proposal_contributes_nothing():
    """An unreachable check is not evidence that its services vanished.

    Counting it as absent would flap the host's whole set whenever one check times out.
    """
    recs = records_from_proposals([_Proposal("df", [_Item("/")], error="push failed")])
    assert recs == []


def test_default_settings_change_nothing():
    """A discovery run must not silently start or stop monitoring on its own."""
    s = DiscoverySettings()
    assert not s.add_new_services and not s.remove_vanished_services
