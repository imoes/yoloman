"""GPO precedence tests (Block L3a) — the exhaustive matrix for
services/gpo.resolve_winner exercised through
services/monitoring.resolve_effective_rule (which computes the OU levels)
plus a few direct unit checks. Pure, no DB: CheckRules are constructed
in-memory and the OU ancestry is a list of lightweight stand-ins exposing
`.id` and `.block_inheritance`.

Covers the six required cases from the L3 plan:
(a) closest OU wins normally, (b) enforced at a higher OU beats a lower one,
(c) multiple enforced → highest level wins, (d) block_inheritance drops
inherited non-enforced rules from above, (e) enforced pierces
block_inheritance, (f) link_order breaks ties within one level.
"""

from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from uuid import uuid4

from bossman.db.models import CheckRule
from bossman.services import gpo
from bossman.services.monitoring import resolve_effective_rule

NOW = datetime(2026, 7, 8, 12, 0, 0, tzinfo=timezone.utc)


def _ou(block=False):
    return SimpleNamespace(id=uuid4(), block_inheritance=block)


def _rule(scope_type, *, ou_id=None, scope_value=None, enforced=False, link_order=100, warn=80.0, created=NOW):
    return CheckRule(
        service_name="CPU", metric="cpu_pct", comparison="gt", warn_threshold=warn, crit_threshold=95.0,
        scope_type=scope_type, scope_ou_id=ou_id, scope_value=scope_value, label_value=None,
        enabled=True, enforced=enforced, link_order=link_order, created_at=created,
    )


def _resolve(rules, ancestry):
    return resolve_effective_rule(rules, "host1", [], "cpu_pct", None, host_ou_ancestry=ancestry)


# --- (a) closest OU wins normally -----------------------------------------


def test_closest_ou_wins_normally():
    root, child = _ou(), _ou()
    ancestry = [root, child]
    shallow = _rule("ou", ou_id=root.id, warn=80.0)
    deep = _rule("ou", ou_id=child.id, warn=70.0)
    assert _resolve([shallow, deep], ancestry).warn_threshold == 70.0


def test_host_beats_every_ou_normally():
    root, child = _ou(), _ou()
    host = _rule("host", scope_value="host1", warn=60.0)
    deep = _rule("ou", ou_id=child.id, warn=70.0)
    assert _resolve([host, deep], [root, child]).warn_threshold == 60.0


# --- (b) enforced at a higher OU beats a lower one ------------------------


def test_enforced_higher_ou_beats_lower():
    root, child = _ou(), _ou()
    enforced_high = _rule("ou", ou_id=root.id, enforced=True, warn=80.0)
    normal_low = _rule("ou", ou_id=child.id, warn=70.0)
    assert _resolve([enforced_high, normal_low], [root, child]).warn_threshold == 80.0


def test_enforced_ou_beats_host():
    root = _ou()
    enforced_ou = _rule("ou", ou_id=root.id, enforced=True, warn=80.0)
    host = _rule("host", scope_value="host1", warn=60.0)
    # Enforced (even at a higher level) can't be overridden by the host rule.
    assert _resolve([enforced_ou, host], [root]).warn_threshold == 80.0


# --- (c) multiple enforced → highest level wins ---------------------------


def test_multiple_enforced_highest_level_wins():
    root, child = _ou(), _ou()
    enforced_high = _rule("ou", ou_id=root.id, enforced=True, warn=80.0)
    enforced_low = _rule("ou", ou_id=child.id, enforced=True, warn=70.0)
    assert _resolve([enforced_high, enforced_low], [root, child]).warn_threshold == 80.0


# --- (d) block_inheritance drops inherited non-enforced from above --------


def test_block_inheritance_drops_inherited_rule():
    host_ou = _ou(block=True)
    global_rule = _rule("global", warn=90.0)
    # With block on the host's OU, the inherited global rule is dropped and
    # nothing governs the metric.
    assert _resolve([global_rule], [host_ou]) is None


def test_block_inheritance_off_keeps_inherited_rule():
    host_ou = _ou(block=False)
    global_rule = _rule("global", warn=90.0)
    assert _resolve([global_rule], [host_ou]).warn_threshold == 90.0


def test_block_inheritance_drops_higher_ou_but_keeps_local():
    parent, child = _ou(), _ou(block=True)
    higher = _rule("ou", ou_id=parent.id, warn=80.0)
    local = _rule("ou", ou_id=child.id, warn=70.0)
    # Block on the child drops the parent's rule; the child's own stays.
    assert _resolve([higher, local], [parent, child]).warn_threshold == 70.0


# --- (e) enforced pierces block_inheritance -------------------------------


def test_enforced_pierces_block_inheritance():
    host_ou = _ou(block=True)
    enforced_global = _rule("global", enforced=True, warn=90.0)
    # Even with block inheritance on, an enforced rule from above still applies.
    assert _resolve([enforced_global], [host_ou]).warn_threshold == 90.0


# --- (f) link_order breaks ties within one level --------------------------


def test_link_order_breaks_tie_within_level():
    root = _ou()
    low_order = _rule("ou", ou_id=root.id, link_order=10, warn=42.0)
    high_order = _rule("ou", ou_id=root.id, link_order=200, warn=99.0)
    # Lowest link_order wins within the same level.
    assert _resolve([low_order, high_order], [root]).warn_threshold == 42.0


def test_created_at_breaks_tie_when_link_order_equal():
    root = _ou()
    older = _rule("ou", ou_id=root.id, link_order=100, warn=1.0, created=NOW - timedelta(hours=1))
    newer = _rule("ou", ou_id=root.id, link_order=100, warn=2.0, created=NOW)
    # Newest wins when level and link_order are equal.
    assert _resolve([older, newer], [root]).warn_threshold == 2.0


# --- direct gpo.resolve_winner unit checks --------------------------------


def test_resolve_winner_empty_returns_none():
    assert gpo.resolve_winner([]) is None


def test_resolve_winner_all_blocked_returns_none():
    # A single non-enforced candidate above the block level is dropped.
    c = gpo.GpoCandidate(obj="x", enforced=False, level=gpo.LEVEL_GLOBAL, link_order=100, created_ts=0.0)
    assert gpo.resolve_winner([c], blocked_level=gpo.LEVEL_OU_BASE) is None


def test_resolve_winner_enforced_survives_block():
    c = gpo.GpoCandidate(obj="x", enforced=True, level=gpo.LEVEL_GLOBAL, link_order=100, created_ts=0.0)
    assert gpo.resolve_winner([c], blocked_level=gpo.LEVEL_OU_BASE) == "x"


# --- (multi-OU) one policy linked to several OUs (check_rule_ou_links) --------


def test_policy_applies_to_every_linked_ou():
    a, b, other = _ou(), _ou(), _ou()
    rid = uuid4()
    rule = _rule("ou", ou_id=a.id)  # primary OU = a
    rule.id = rid
    links = {rid: {b.id}}  # additionally linked to b
    R = lambda anc: resolve_effective_rule([rule], "h", [], "cpu_pct", None, host_ou_ancestry=anc, rule_ou_links=links)
    assert R([a]) is rule          # primary OU
    assert R([b]) is rule          # linked OU
    assert R([other]) is None      # neither → does not apply


def test_linked_ou_deepens_level_so_policy_wins():
    root, child = _ou(), _ou()  # ancestry root → child
    rid = uuid4()
    linked = _rule("ou", ou_id=root.id, warn=80.0)  # primary root, but…
    linked.id = rid
    links = {rid: {child.id}}                        # …also linked to the deeper child
    shallow = _rule("ou", ou_id=root.id, warn=90.0)  # a plain root-level rule
    # `linked` resolves at child depth (its deepest linked OU on the path),
    # so it beats the shallower root rule under normal closest-wins precedence.
    got = resolve_effective_rule([linked, shallow], "h", [], "cpu_pct", None, host_ou_ancestry=[root, child], rule_ou_links=links)
    assert got.warn_threshold == 80.0
