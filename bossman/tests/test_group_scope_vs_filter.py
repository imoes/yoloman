"""scope_type='group' and the host_groups FILTER are different tools — pinned, not remembered.

Punkt 4 of the filter work asked whether group-as-SCOPE should be retired now that a group can be a
FILTER on any rule ("scope=global AND filter=group"). Measured answer: no. They are not two ways to
say one thing, and these tests are the observation point for why — so that "let's just collapse them"
fails here instead of quietly changing which rule wins on somebody's fleet.

Two properties carry the difference, and a filter has neither:

  1. RANK. LEVEL_GROUP sits strictly between LEVEL_GLOBAL and LEVEL_OU_BASE. A group-scoped rule
     therefore beats a global one by SPECIFICITY. Turned into "global + filter", it would drop to
     LEVEL_GLOBAL, tie with every plain global rule, and the winner would fall to link_order /
     created_at — arbitrary rather than specific.

  2. NESTING SPECIFICITY. Group names are paths, and services/monitoring ranks a group-scoped rule by
     its depth (scope_value.count("/")), so "Europe/Latvia" outranks "Europe". `host_groups: [...]` is
     a flat list: it has no notion of one group being more specific than another, so that ordering has
     no equivalent on the filter side.

What the filter has instead: it keeps the rank of the scope it is attached to, which is exactly what
"this OU's rule, but only for webservers" needs. Different question, different tool.

The coherence worry that prompted the question — "a group with a LEVEL behaves like a place in the
tree" — is answered by what the level IS: a rank in the merge order, not a position in the OU tree. A
host's place is agents.ou_id, and that is still exactly one.
"""

from bossman.services import gpo


def _cand(level: int, *, link_order: int = 100, subrank: int = 0, tag: str) -> gpo.GpoCandidate:
    return gpo.GpoCandidate(obj=tag, enforced=False, level=level, link_order=link_order,
                            created_ts=0.0, subrank=subrank)


def test_group_ranks_between_global_and_ou():
    """The ordering that makes group-as-scope a distinct tool. Collapsing it into the filter would
    erase this line."""
    assert gpo.LEVEL_GLOBAL < gpo.LEVEL_GROUP < gpo.LEVEL_OU_BASE
    assert gpo.LEVEL_OU_BASE < gpo.LEVEL_SITE < gpo.LEVEL_HOST


def test_a_group_scoped_rule_beats_a_global_one():
    winner = gpo.resolve_winner([
        _cand(gpo.LEVEL_GLOBAL, tag="global"),
        _cand(gpo.LEVEL_GROUP, tag="group"),
    ])
    assert getattr(winner, "obj", winner) == "group"


def test_an_ou_rule_beats_a_group_one():
    """The other side of the same line — and the reason a host in an OU is not overridden by a group
    it happens to be in."""
    winner = gpo.resolve_winner([
        _cand(gpo.LEVEL_GROUP, tag="group"),
        _cand(gpo.LEVEL_OU_BASE, tag="ou"),
    ])
    assert getattr(winner, "obj", winner) == "ou"


def test_nested_groups_order_by_depth_within_the_level():
    """services/monitoring ranks a group-scoped rule by scope_value.count("/"), so a rule for
    "Europe/Latvia" outranks one for "Europe". A flat host_groups list cannot express this."""
    winner = gpo.resolve_winner([
        _cand(gpo.LEVEL_GROUP, subrank=0, tag="Europe"),
        _cand(gpo.LEVEL_GROUP, subrank=1, tag="Europe/Latvia"),
    ])
    assert getattr(winner, "obj", winner) == "Europe/Latvia"


def test_two_globals_fall_back_to_link_order():
    """What "global + filter" would degrade to: no specificity left, so an arbitrary tiebreak decides.
    Asserted so the cost of collapsing the two tools is visible rather than argued about."""
    winner = gpo.resolve_winner([
        _cand(gpo.LEVEL_GLOBAL, link_order=200, tag="later"),
        _cand(gpo.LEVEL_GLOBAL, link_order=10, tag="earlier"),
    ])
    assert getattr(winner, "obj", winner) == "earlier"
