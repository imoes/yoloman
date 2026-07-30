"""Discovery lifecycle: what changed since the last run — Checkmk's QualifiedDiscovery.

Checkmk's discovery does not just list what is on a host; it COMPARES that against what
was on it last time. `QualifiedDiscovery` (cmk/checkengine/discovery/types.py) takes the
persisted set (`preexisting`) and the fresh one (`current`) and classifies every service:

    new        in current, not in preexisting
    vanished   in preexisting, not in current
    changed    in both, but the comparator differs
    unchanged  in both, comparator equal

Two functions on the record decide this, and keeping them apart is the whole point:

    id()          (check_name, item)              -> identity
    comparator()  (parameters, service_labels)    -> whether it changed

A service whose thresholds changed is the SAME service with new settings — not a new
service and not a vanished-plus-new pair. Anything that folded parameters into the
identity would report churn on every parameter edit.

This module is deliberately free of DB and FastAPI so `classify()` is a pure function
over plain records (same reason services/discovery.py keeps its orchestration testable
with a fake client). `reconcile()` is the thin DB layer on top of it.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Iterable

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import DiscoveredService, HostLabel

# The four discovery lifecycle states, mirroring the DB CHECK constraint.
STATE_UNDECIDED = "undecided"  # Checkmk's "new" / unmonitored
STATE_MONITORED = "monitored"
STATE_VANISHED = "vanished"
STATE_IGNORED = "ignored"


@dataclass(frozen=True)
class ServiceRecord:
    """One discovered service, in the shape the comparison needs.

    Mirrors Checkmk's AutocheckEntry (cmk/checkengine/plugins/_discovery.py). `item` is
    "" for a single-service check rather than None — see the DiscoveredService model for
    why that deviation exists.
    """

    check_name: str
    item: str = ""
    parameters: dict[str, Any] = field(default_factory=dict)
    service_labels: dict[str, str] = field(default_factory=dict)

    def id(self) -> tuple[str, str]:
        """The service's identity. As long as this is stable it is "the same" service."""
        return (self.check_name, self.item)

    def comparator(self) -> tuple[str, str]:
        """What makes it "changed" rather than "the same".

        Compared as sorted-key JSON-ish strings so dict ordering never fakes a change —
        the equivalent of Checkmk comparing two Mappings for equality.
        """
        return (_stable(self.parameters), _stable(self.service_labels))


def _stable(d: dict[str, Any]) -> str:
    """A dict rendered order-independently, for comparison only."""
    return repr(sorted((str(k), repr(v)) for k, v in (d or {}).items()))


@dataclass(frozen=True)
class DiscoverySettings:
    """Which transitions a discovery run is allowed to act on.

    The five flags are Checkmk's, verbatim (cmk/checkengine/discovery/types.py's
    DiscoverySettings): a run can add new services, remove vanished ones, update host
    labels, and take over changed labels/parameters — independently. Checkmk derives
    them from a DiscoveryMode (NEW / REMOVE / FIXALL / REFRESH); we expose the flags
    directly because our caller is an API request, not a CLI mode word.

    The default is the SAFE one: record everything, change nothing. A discovery run must
    never silently start or stop monitoring something — that is the operator's decision
    (or an explicit automatic-discovery job's).
    """

    add_new_services: bool = False
    remove_vanished_services: bool = False
    update_host_labels: bool = False
    update_changed_service_labels: bool = True
    update_changed_service_parameters: bool = False


@dataclass
class Transitions:
    """The classification result: every service sorted into one of four buckets.

    `changed` carries both sides so a caller can show what changed (and so
    update_changed_* can apply only the half it is allowed to).
    """

    new: list[ServiceRecord] = field(default_factory=list)
    unchanged: list[ServiceRecord] = field(default_factory=list)
    changed: list[tuple[ServiceRecord, ServiceRecord]] = field(default_factory=list)  # (previous, current)
    vanished: list[ServiceRecord] = field(default_factory=list)

    def counts(self) -> dict[str, int]:
        return {
            "new": len(self.new),
            "unchanged": len(self.unchanged),
            "changed": len(self.changed),
            "vanished": len(self.vanished),
        }


def classify(preexisting: Iterable[ServiceRecord], current: Iterable[ServiceRecord]) -> Transitions:
    """Port of Checkmk's QualifiedDiscovery.__init__.

    Identity decides which bucket; the comparator decides changed vs unchanged. Both
    sides are keyed by id() first, so a duplicate id in either input collapses to one
    entry (Checkmk's _deduplicate does the same, keeping the first).
    """
    pre = {r.id(): r for r in preexisting}
    cur = {r.id(): r for r in current}

    out = Transitions()
    out.vanished = [r for key, r in pre.items() if key not in cur]
    out.new = [r for key, r in cur.items() if key not in pre]
    for key, previous in pre.items():
        if key not in cur:
            continue
        now = cur[key]
        if previous.comparator() == now.comparator():
            out.unchanged.append(now)
        else:
            out.changed.append((previous, now))
    return out


def records_from_proposals(proposals: Iterable[Any]) -> list[ServiceRecord]:
    """CheckProposal objects (services/discovery.py) -> ServiceRecords.

    One record per discovered ITEM, because that is the granularity of a service. A
    proposal that errored contributes nothing: an unreachable check is not evidence that
    its services vanished, and treating it as such would flap the whole host's set every
    time one check times out.
    """
    out: list[ServiceRecord] = []
    for p in proposals:
        if getattr(p, "error", ""):
            continue
        for item in getattr(p, "items", []) or []:
            out.append(
                ServiceRecord(
                    check_name=p.check_name,
                    item=str(getattr(item, "item", "") or ""),
                    parameters=dict(getattr(item, "params", None) or {}),
                    service_labels=dict(getattr(item, "service_labels", None) or {}),
                )
            )
    return out


async def reconcile(
    session: AsyncSession,
    agent,
    proposals: Iterable[Any],
    settings: DiscoverySettings | None = None,
) -> Transitions:
    """Write a discovery run's outcome into discovered_services, return the transitions.

    Idempotent by construction: rows are keyed by (agent, check_name, item), so running
    the same discovery twice moves last_seen_at and nothing else. That also fixes the old
    /discover/apply, which inserted an assignment row unconditionally and duplicated it
    on every repeat call.

    What it does NOT do: start or stop monitoring anything. A newly found service lands
    as `undecided`, a missing one becomes `vanished`, and both wait for a decision unless
    the caller passed the corresponding settings flag. Does not commit — the caller owns
    the transaction, like the rest of services/monitoring.py.
    """
    settings = settings or DiscoverySettings()
    now = datetime.now(timezone.utc)
    current = records_from_proposals(proposals)

    rows = (
        await session.scalars(select(DiscoveredService).where(DiscoveredService.agent_id == agent.id))
    ).all()
    by_id = {(r.check_name, r.item): r for r in rows}

    # An ignored service must not be resurrected as "new" on the next run — that is the
    # entire point of remembering the decision. It takes part in the comparison (so it
    # counts as still present) but keeps its state.
    preexisting = [
        ServiceRecord(r.check_name, r.item, dict(r.parameters or {}), dict(r.service_labels or {}))
        for r in rows
        if r.state != STATE_VANISHED
    ]

    transitions = classify(preexisting, current)

    for rec in transitions.new:
        row = by_id.get(rec.id())
        if row is None:
            session.add(
                DiscoveredService(
                    tenant_id=agent.tenant_id,
                    agent_id=agent.id,
                    check_name=rec.check_name,
                    item=rec.item,
                    parameters=rec.parameters,
                    service_labels=rec.service_labels,
                    state=STATE_MONITORED if settings.add_new_services else STATE_UNDECIDED,
                    first_seen_at=now,
                    last_seen_at=now,
                )
            )
        else:
            # Previously vanished and now back: same identity, so it resumes its old
            # state rather than being treated as a brand-new find.
            row.parameters = rec.parameters
            row.service_labels = rec.service_labels
            row.state = STATE_UNDECIDED if row.state == STATE_VANISHED else row.state
            row.last_seen_at = now

    for rec in transitions.unchanged:
        if (row := by_id.get(rec.id())) is not None:
            row.last_seen_at = now

    for previous, now_rec in transitions.changed:
        row = by_id.get(now_rec.id())
        if row is None:
            continue
        row.last_seen_at = now
        row.last_changed_at = now
        if settings.update_changed_service_labels:
            row.service_labels = now_rec.service_labels
        if settings.update_changed_service_parameters:
            row.parameters = now_rec.parameters

    for rec in transitions.vanished:
        row = by_id.get(rec.id())
        if row is None:
            continue
        if settings.remove_vanished_services:
            await session.delete(row)
        else:
            row.state = STATE_VANISHED
            row.last_changed_at = now

    await session.flush()
    return transitions


async def reconcile_host_labels(
    session: AsyncSession, agent, labels: dict[str, str], *, update: bool = True
) -> dict[str, int]:
    """Same treatment for host labels, which Checkmk also runs through QualifiedDiscovery.

    Only `source='discovered'` labels are touched: a label a human set explicitly (or a
    ruleset produced) is not discovery's to remove. Returns per-transition counts.
    """
    rows = (
        await session.scalars(
            select(HostLabel).where(HostLabel.agent_id == agent.id, HostLabel.source == "discovered")
        )
    ).all()
    existing = {r.key: r for r in rows}
    now = datetime.now(timezone.utc)
    counts = {"new": 0, "unchanged": 0, "changed": 0, "vanished": 0}

    for key, value in (labels or {}).items():
        row = existing.pop(key, None)
        if row is None:
            counts["new"] += 1
            if update:
                session.add(
                    HostLabel(
                        tenant_id=agent.tenant_id, agent_id=agent.id, key=str(key),
                        value=str(value), source="discovered", first_seen_at=now, last_seen_at=now,
                    )
                )
        elif row.value != str(value):
            counts["changed"] += 1
            if update:
                row.value = str(value)
                row.last_seen_at = now
        else:
            counts["unchanged"] += 1
            if update:
                row.last_seen_at = now

    # Whatever is left in `existing` was not reported this run.
    for row in existing.values():
        counts["vanished"] += 1
        if update:
            await session.delete(row)

    await session.flush()
    return counts
