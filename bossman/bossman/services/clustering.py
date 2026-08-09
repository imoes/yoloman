"""C1/C2: cluster hosts and how their services are aggregated.

Ported from Checkmk's `packages/cmk-check-engine/cmk/checkengine/checking/cluster_mode.py`
(394 LOC there, and the most directly portable piece of that batch) plus the ownership half
of `cmk/base/config.py`'s `ClusteringConfig._effective_host`.

**The algorithm.** Checkmk buckets nodes by the worst state among that node's results, then
picks the bucket chosen by a selector — `State.worst` for mode "worst", `State.best` for
mode "best" — and pivots on one node of that bucket (the preferred one if it is in there,
otherwise the alphabetically first, so the choice is deterministic and explainable). "best"
is the answer to "the cluster is fine as long as ONE node is fine"; "worst" is "any node's
problem is the cluster's problem". "failover" always pivots on the primary node and raises
a WARN when a secondary node is also reporting, because in a failover cluster two active
nodes is itself the news.

Simpler here in one respect: a Checkmk node contributes a *list* of results per service, so
it first has to reduce that list with `State.worst`. Our Service row carries exactly one
state, so that step is already done.

**Deliberately not ported: "native" mode.** Checkmk lets a plugin supply its own
`cluster_check_function` and falls back to an UNKNOWN "this service does not implement a
native cluster mode" when it has none. None of our Starlark checks have such a function —
the check contract has no cluster entry point at all — so offering the mode would mean
offering a setting whose only possible outcome is that error message.
"""

from __future__ import annotations

from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass

# Worst-first ordering. Matches monitoring._SEVERITY / api/security's ranking idea: CRIT is
# worse than UNKNOWN is worse than WARN. Checkmk's State enum orders the same way
# (OK < WARN < UNKNOWN < CRIT for `worst`).
_RANK = {"OK": 0, "WARN": 1, "UNKNOWN": 2, "CRIT": 3}

MODES = ("worst", "best", "failover")


class ClusteringError(ValueError):
    """An aggregation that cannot be performed (unknown mode)."""


@dataclass(frozen=True)
class NodeState:
    """One node's verdict on one service."""

    node: str
    state: str
    output: str = ""


@dataclass(frozen=True)
class Aggregate:
    """The cluster's verdict, plus why — the "why" is the point.

    `pivot` is the node the state was taken from, `contributing` every node that reported.
    Without those an aggregated CRIT is unactionable: it says the cluster is broken but not
    which node to look at.
    """

    state: str
    output: str
    pivot: str
    contributing: tuple[str, ...]


def worst_state(states: Iterable[str]) -> str:
    """The worst of these states; OK when there are none."""
    return max((s for s in states), key=lambda s: _RANK.get(s, _RANK["UNKNOWN"]), default="OK")


def best_state(states: Iterable[str]) -> str:
    return min((s for s in states), key=lambda s: _RANK.get(s, _RANK["UNKNOWN"]), default="OK")


def _selected_nodes(nodes: Sequence[NodeState], mode: str) -> list[str]:
    """Checkmk's `_get_selected_nodes`: bucket by state, then take the selected bucket."""
    by_state: dict[str, list[str]] = {}
    for n in nodes:
        by_state.setdefault(n.state, []).append(n.node)
    if not by_state:
        return []
    chosen = best_state(by_state) if mode == "best" else worst_state(by_state)
    return sorted(by_state[chosen])


def aggregate(nodes: Sequence[NodeState], mode: str, *, primary: str | None = None) -> Aggregate | None:
    """The cluster's state for one service. None when no node reported it at all.

    Returning None rather than UNKNOWN is deliberate: "no node has this service" is not a
    problem with the cluster, it means the service is not clustered here — and inventing an
    UNKNOWN service on the cluster would be a permanent, unfixable alert.
    """
    reporting = [n for n in nodes if n.state]
    if not reporting:
        return None
    if mode not in MODES:
        raise ClusteringError(f"unknown aggregation mode {mode!r} (expected one of {', '.join(MODES)})")

    contributing = tuple(sorted(n.node for n in reporting))
    by_node = {n.node: n for n in reporting}

    if mode == "failover":
        # The primary decides. A secondary that is also reporting is itself the news, so it
        # lifts an otherwise-OK cluster to WARN — that is Checkmk's unpreferred_node_state.
        pivot = primary if primary in by_node else _selected_nodes(reporting, "worst")[0]
        state = by_node[pivot].state
        others = [n for n in contributing if n != pivot]
        if others and state == "OK":
            state = "WARN"
        detail = f"failover on {pivot}"
        if others:
            detail += f"; also reporting: {', '.join(others)}"
        return Aggregate(state=state, output=f"{detail} — {by_node[pivot].output}".strip(" —"),
                         pivot=pivot, contributing=contributing)

    selected = _selected_nodes(reporting, mode)
    # Preferred node wins the tie if it is in the selected bucket; else first by name, so
    # the same input always names the same node.
    pivot = primary if primary in selected else selected[0]
    state = by_node[pivot].state
    label = "best" if mode == "best" else "worst"
    detail = f"{label} of {len(contributing)} node(s): {pivot}"
    if len(contributing) > 1:
        detail += f" (of {', '.join(contributing)})"
    return Aggregate(state=state, output=f"{detail} — {by_node[pivot].output}".strip(" —"),
                     pivot=pivot, contributing=contributing)


def owns_service(patterns: Iterable[str], service_name: str) -> bool:
    """Does this service belong to the CLUSTER rather than to the node?

    Checkmk answers this with `_effective_host(node, service)` over three rulesets; we take
    an explicit list of exact names, with a trailing "*" allowed as a prefix match ("Disk *"
    for every mount). Explicit because the question is small and a second precedence system
    beside GPO would be the very Checkmk complexity this project set out to avoid.
    """
    for raw in patterns or ():
        pattern = str(raw).strip()
        if not pattern:
            continue
        if pattern.endswith("*"):
            if service_name.startswith(pattern[:-1]):
                return True
        elif service_name == pattern:
            return True
    return False


def cluster_service_names(patterns: Iterable[str], node_services: Mapping[str, Iterable[str]]) -> list[str]:
    """Every service name that any node has and the cluster claims, sorted."""
    pats = list(patterns or ())
    names = {name for names_ in node_services.values() for name in names_ if owns_service(pats, name)}
    return sorted(names)


# ---------------------------------------------------------------------------
# DB side: turn node service states into the cluster's own services


async def aggregate_cluster(session, cluster_agent, config, node_agents) -> list:
    """Writes one Service row on the cluster for each service it claims.

    Runs once per poll cycle, AFTER every node has been evaluated — an aggregate computed
    from half-fresh node states would flap on nothing but poll ordering.

    Reuses `_upsert_service_state`, so a cluster service gets the same soft/hard debouncing,
    history, acknowledgement, downtime coverage and notification path as any other service.
    The cluster is a host; its services are services.
    """
    from datetime import datetime, timezone

    from sqlalchemy import select

    from bossman.db.models import Service
    from bossman.services.monitoring import DEFAULT_MAX_ATTEMPTS, _upsert_service_state

    if not node_agents:
        return []

    names_by_id = {a.id: a.name for a in node_agents}
    rows = (
        await session.scalars(select(Service).where(Service.agent_id.in_(list(names_by_id))))
    ).all()

    per_node: dict[str, list[str]] = {name: [] for name in names_by_id.values()}
    states: dict[str, list[NodeState]] = {}
    for svc in rows:
        node = names_by_id[svc.agent_id]
        per_node[node].append(svc.name)
        states.setdefault(svc.name, []).append(NodeState(node=node, state=svc.state, output=svc.output or ""))

    primary = names_by_id.get(config.primary_node_id) if config.primary_node_id else None
    now = datetime.now(timezone.utc)
    touched = []
    for name in cluster_service_names(config.service_patterns, per_node):
        verdict = aggregate(states.get(name, []), config.aggregation_mode, primary=primary)
        if verdict is None:
            continue
        touched.append(
            await _upsert_service_state(
                session, cluster_agent.id, name, verdict.state, None, verdict.output, now,
                DEFAULT_MAX_ATTEMPTS, metric="", rule_id=None,
                agent_name=cluster_agent.name, agent_tags=cluster_agent.tags,
            )
        )
    return touched


async def aggregate_all_clusters(session) -> list:
    """Every configured cluster. Returns the touched services for notification dispatch."""
    from sqlalchemy import select

    from bossman.db.models import Agent, ClusterNode, HostCluster

    configs = (await session.scalars(select(HostCluster))).all()
    if not configs:
        return []
    touched = []
    for config in configs:
        cluster = await session.get(Agent, config.agent_id)
        if cluster is None:
            continue
        node_ids = list(
            (
                await session.scalars(
                    select(ClusterNode.node_agent_id).where(ClusterNode.cluster_agent_id == config.agent_id)
                )
            ).all()
        )
        if not node_ids:
            continue
        nodes = (await session.scalars(select(Agent).where(Agent.id.in_(node_ids)))).all()
        touched += await aggregate_cluster(session, cluster, config, list(nodes))
    return touched
