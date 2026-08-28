"""`host_groups` as a rule CONDITION — the AND of OU scope and group membership.

A rule's scope is exactly one of OU / group / site, so "everything in this OU that is also a
webserver" could not be said at all. Adding a second scope would have meant deciding which of two
scopes wins, which is the ordered-ruleset complexity this design deliberately avoids (see the
rule_conditions module header). A condition composes instead: the scope still decides inheritance
and GPO precedence, the condition narrows.

It lands in ONE place — rule_conditions.matches plus the single build_match_context — so check
assignments, config policies, threshold rules, template links and event rules all gain it together.
"""

import pytest

from bossman.services.rule_conditions import MatchContext, matches


def ctx(groups=(), **kw):
    return MatchContext(host_name=kw.pop("host_name", "web01"), host_groups=list(groups), **kw)


def test_no_condition_still_matches_everything():
    """Every rule written before this field existed must behave exactly as before."""
    assert matches(None, ctx(["prod"])) is True
    assert matches({}, ctx()) is True


def test_a_bare_list_means_any_of_these_groups():
    assert matches({"host_groups": ["webservers"]}, ctx(["webservers", "prod"])) is True
    assert matches({"host_groups": ["webservers", "dbservers"]}, ctx(["dbservers"])) is True
    assert matches({"host_groups": ["webservers"]}, ctx(["prod"])) is False
    assert matches({"host_groups": ["webservers"]}, ctx([])) is False


def test_the_and_with_the_ou_is_the_point():
    """Scope narrows by OU (host_folder), the condition narrows by group. Both must hold."""
    cond = {"host_folder": "/Europe", "host_groups": ["webservers"]}
    in_ou_and_group = ctx(["webservers"], ou_paths=["/Europe", "/Europe/Latvia"])
    in_ou_only = ctx(["dbservers"], ou_paths=["/Europe"])
    in_group_only = ctx(["webservers"], ou_paths=["/Asia"])
    assert matches(cond, in_ou_and_group) is True
    assert matches(cond, in_ou_only) is False
    assert matches(cond, in_group_only) is False


def test_negation_means_in_NONE_of_them():
    """The subtle one, and the reason this is not _matches_name applied per value.

    host_groups is a SET. If negation were evaluated per value and OR-ed, {"$nor": ["staging"]}
    would read as "at least one group is not staging" — true for nearly every host, i.e. the
    opposite of what was written. It must mean the host is in none of the named groups.
    """
    cond = {"host_groups": {"$nor": ["staging"]}}
    assert matches(cond, ctx(["prod"])) is True
    assert matches(cond, ctx(["staging"])) is False
    # The trap: a host in staging AND prod must still be excluded.
    assert matches(cond, ctx(["staging", "prod"])) is False
    assert matches(cond, ctx([])) is True


def test_an_exact_name_does_not_match_a_longer_one():
    """Group "web" must not select "web-staging" — names are escaped and anchored, as host_name is."""
    assert matches({"host_groups": ["web"]}, ctx(["web-staging"])) is False
    assert matches({"host_groups": ["web"]}, ctx(["web"])) is True


def test_regex_is_available_like_everywhere_else():
    assert matches({"host_groups": [{"$regex": "^web"}]}, ctx(["webservers"])) is True
    assert matches({"host_groups": [{"$regex": "^web"}]}, ctx(["dbservers"])) is False


def test_an_empty_list_matches_everything_not_nothing():
    """Consistent with host_name: an empty condition is "unset", not "impossible". A picker that
    starts empty must not silently disable the rule it belongs to."""
    assert matches({"host_groups": []}, ctx(["prod"])) is True
    assert matches({"host_groups": {"$nor": []}}, ctx(["prod"])) is True


def test_group_paths_inherit_because_the_context_expands_them():
    """A condition on a parent group reaches its children without being restated — the context is
    built from resolve_host_group_ids, which already expands paths ("Europe" governs
    "Europe/Latvia"). Asserted here against the shape that builder produces."""
    assert matches({"host_groups": ["Europe"]}, ctx(["Europe", "Europe/Latvia"])) is True


@pytest.mark.parametrize("other", ["host_tags", "host_facts", "host_vars"])
def test_it_ands_with_the_other_dimensions(other):
    cond = {"host_groups": ["prod"], other: {"k": "v"}}
    good = ctx(["prod"], **{other: {"k": "v"}})
    wrong_value = ctx(["prod"], **{other: {"k": "other"}})
    wrong_group = ctx(["dev"], **{other: {"k": "v"}})
    assert matches(cond, good) is True
    assert matches(cond, wrong_value) is False
    assert matches(cond, wrong_group) is False
