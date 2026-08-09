"""C2 aggregation, ported from Checkmk's cluster_mode.py — pure, no DB."""

import pytest

from bossman.services.clustering import (
    Aggregate,
    ClusteringError,
    NodeState,
    aggregate,
    best_state,
    cluster_service_names,
    owns_service,
    worst_state,
)

N1 = NodeState("node-a", "OK", "42% used")
N2 = NodeState("node-b", "CRIT", "91% used")
N3 = NodeState("node-c", "WARN", "83% used")


def test_state_ordering_matches_the_reference():
    """OK < WARN < UNKNOWN < CRIT for `worst`, as in Checkmk's State enum."""
    assert worst_state(["OK", "WARN", "UNKNOWN", "CRIT"]) == "CRIT"
    assert worst_state(["OK", "WARN", "UNKNOWN"]) == "UNKNOWN"
    assert worst_state(["OK", "WARN"]) == "WARN"
    assert best_state(["CRIT", "UNKNOWN", "WARN", "OK"]) == "OK"
    assert worst_state([]) == "OK", "nothing to complain about"


def test_worst_mode_takes_any_nodes_problem():
    got = aggregate([N1, N2, N3], "worst")
    assert got.state == "CRIT"
    assert got.pivot == "node-b"
    assert got.contributing == ("node-a", "node-b", "node-c")


def test_best_mode_is_ok_while_one_node_is_ok():
    """The actual point of a cluster: "healthy as long as one node is healthy"."""
    got = aggregate([N1, N2, N3], "best")
    assert got.state == "OK"
    assert got.pivot == "node-a"


def test_best_mode_still_reports_when_every_node_is_bad():
    got = aggregate([NodeState("a", "CRIT"), NodeState("b", "WARN")], "best")
    assert got.state == "WARN", "the least-bad node, not a fabricated OK"


def test_the_pivot_is_named_so_the_verdict_is_actionable():
    """An aggregated CRIT that does not say which node to look at is unactionable."""
    got = aggregate([N1, N2], "worst")
    assert "node-b" in got.output
    assert "91% used" in got.output, "the pivot's own summary must survive aggregation"


def test_ties_are_broken_deterministically_by_name():
    """Same input, same named node — otherwise the summary flaps between equal nodes."""
    nodes = [NodeState("zeta", "CRIT"), NodeState("alpha", "CRIT")]
    assert aggregate(nodes, "worst").pivot == "alpha"
    assert aggregate(list(reversed(nodes)), "worst").pivot == "alpha"


def test_a_preferred_node_wins_a_tie_but_cannot_hide_a_worse_one():
    both_crit = [NodeState("alpha", "CRIT"), NodeState("zeta", "CRIT")]
    assert aggregate(both_crit, "worst", primary="zeta").pivot == "zeta"
    # zeta is fine, alpha is not: in "worst" mode the preference must not mask alpha.
    mixed = [NodeState("alpha", "CRIT"), NodeState("zeta", "OK")]
    got = aggregate(mixed, "worst", primary="zeta")
    assert got.state == "CRIT" and got.pivot == "alpha"


def test_failover_pivots_on_the_primary():
    got = aggregate([NodeState("standby", "OK"), NodeState("active", "WARN")], "failover", primary="active")
    assert got.pivot == "active"
    assert got.state == "WARN"
    assert "failover on active" in got.output


def test_failover_warns_when_a_secondary_also_reports():
    """Two active nodes in a failover cluster is itself the news (Checkmk's
    unpreferred_node_state=WARN)."""
    got = aggregate([NodeState("active", "OK"), NodeState("standby", "OK")], "failover", primary="active")
    assert got.state == "WARN"
    assert "also reporting: standby" in got.output


def test_failover_alone_on_the_primary_stays_ok():
    got = aggregate([NodeState("active", "OK")], "failover", primary="active")
    assert got.state == "OK"
    assert "also reporting" not in got.output


def test_failover_without_a_reporting_primary_falls_back_deterministically():
    """The primary is gone (or was deleted — the FK is ON DELETE SET NULL)."""
    got = aggregate([NodeState("b", "WARN"), NodeState("a", "CRIT")], "failover", primary="missing")
    assert got.pivot == "a", "worst-first, then by name — never arbitrary"


def test_no_reporting_node_yields_nothing_rather_than_unknown():
    """"No node has this service" is not a cluster problem.

    Inventing an UNKNOWN service on the cluster would be a permanent alert nobody can clear
    — there is no node to fix.
    """
    assert aggregate([], "worst") is None
    assert aggregate([NodeState("a", "")], "worst") is None


def test_an_unknown_mode_is_an_error_not_a_silent_default():
    with pytest.raises(ClusteringError):
        aggregate([N1], "native")
    with pytest.raises(ClusteringError):
        aggregate([N1], "")


def test_single_node_cluster_reports_that_node():
    got = aggregate([N3], "worst")
    assert got == Aggregate(state="WARN", output="worst of 1 node(s): node-c — 83% used",
                            pivot="node-c", contributing=("node-c",))


# ---------------------------------------------------------------------------
# C1 — which services belong to the cluster rather than to the node


def test_exact_and_prefix_ownership():
    assert owns_service(["Memory"], "Memory") is True
    assert owns_service(["Memory"], "Memory bank 2") is False, "exact means exact"
    assert owns_service(["Disk *"], "Disk /var") is True
    assert owns_service(["Disk *"], "Disk IOPS") is True
    assert owns_service(["Disk *"], "Diskspace") is False, "the space in the pattern matters"


def test_no_patterns_claims_nothing():
    """An empty list must not accidentally mean "everything" — that would move every
    service off its node the moment a cluster is created."""
    assert owns_service([], "Memory") is False
    assert owns_service(None, "Memory") is False


def test_blank_patterns_are_ignored():
    assert owns_service(["", "  ", "Memory"], "Memory") is True
    assert owns_service(["", "  "], "Memory") is False


def test_cluster_service_names_unions_across_nodes():
    """A service present on only one node still belongs to the cluster — that is exactly
    the failover case."""
    names = cluster_service_names(
        ["Memory", "Disk *"],
        {"a": ["Memory", "Disk /", "CPU load"], "b": ["Memory", "Disk /var"]},
    )
    assert names == ["Disk /", "Disk /var", "Memory"]
    assert "CPU load" not in names
