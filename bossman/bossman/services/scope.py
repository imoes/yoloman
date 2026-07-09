"""Shared scope model (Block N1) — the one place that answers "does this
rule's scope cover this (host, service)?".

Thresholds keep their winner-take-all GPO resolution in services.gpo (one
effective threshold per host/metric); notifications are ADDITIVE (every
matching rule fires) and use this module as a pure MATCH filter. Both share
the same scope vocabulary so "scope to a host / a service / an OU / a policy"
means the same thing everywhere:

    global | ou | group | host | service | policy

Pure and DB-free: callers pass the already-loaded host/service context (the
notification dispatcher resolves it once per event).
"""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class HostCtx:
    """The event host, resolved once by the caller."""

    name: str
    groups: list[str] = field(default_factory=list)
    # Every OU id on the host's ancestry (root → host-OU). A rule scoped to an
    # OU covers the host iff that OU id is in this set (i.e. an ancestor).
    ou_ids: frozenset[str] = field(default_factory=frozenset)


@dataclass
class ServiceCtx:
    """The event's service."""

    service_name: str
    # Plans whose generated services include this service on this host — the
    # "service policy" membership.
    policy_ids: frozenset[str] = field(default_factory=frozenset)


@dataclass
class Scope:
    """A rule's target, read from its scope columns."""

    scope_type: str  # global | ou | group | host | service | policy
    ou_id: str | None = None
    value: str | None = None  # group name (group) or agent name (host / service)
    service_name: str | None = None  # for scope_type=service
    plan_id: str | None = None  # for scope_type=policy


def scope_covers(scope: Scope, host: HostCtx, service: ServiceCtx) -> bool:
    """Does `scope` govern the given `(host, service)`? Used by the additive
    notification matcher — every rule whose scope covers the event fires."""
    st = scope.scope_type
    if st == "global":
        return True
    if st == "ou":
        return scope.ou_id is not None and scope.ou_id in host.ou_ids
    if st == "group":
        # Nested-group aware, matching CheckRule's own semantics (Zabbix
        # gap-analysis K2b): a rule scoped to "Europe" also covers a host in
        # "Europe/Latvia".
        prefix = (scope.value or "") + "/"
        return any(g == scope.value or g.startswith(prefix) for g in host.groups)
    if st == "host":
        return scope.value == host.name
    if st == "service":
        return scope.value == host.name and scope.service_name == service.service_name
    if st == "policy":
        return scope.plan_id is not None and scope.plan_id in service.policy_ids
    return False


__all__ = ["HostCtx", "ServiceCtx", "Scope", "scope_covers"]
