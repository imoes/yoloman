"""Background metrics + connection-edge poller (see docs/plan.md's
Bossman plan, section B.4): for each enrolled agent, pulls
GET /api/v1/metrics and GET /api/v1/net/connections/dump on an interval,
cursor-based off that agent's own last-successful-pull timestamps (see
Agent.last_metrics_pulled_at/last_edges_pulled_at) so a Bossman restart or
outage doesn't lose data — it just catches up from where it left off on
the next run. Bounded concurrency via asyncio.Semaphore rather than a task
queue (Celery/Redis): comfortably sufficient at this project's targeted
fleet size (~100 hosts).

Framework-free (no FastAPI import) like bossman.services.enrollment, for
the same reason: reachable from the app's background task, a future CLI,
and tests without duplicating logic.
"""

from __future__ import annotations

import asyncio
import json
import logging
import uuid
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

from sqlalchemy import delete, func, select, text
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from bossman.config import Settings
from bossman.db.models import Agent, AgentObservedState, HostEdge, Metric, MetricRaw
from bossman.services import agent_release, knowledge_index, notification, registry_policy
from bossman.services.agent_client import AgentClient, AgentClientError, client_for
from bossman.services.edge_identity import (
    EPHEMERAL_FLOOR,
    collapse_client_ports,
    high_ports_by_key,
)
from bossman.services.monitoring import (
    evaluate_assigned_checks,
    evaluate_host,
    expire_acknowledgements,
    ingest_agent_checks,
    is_infra_agent,
    stale_after_for,
    update_host_alive,
)

logger = logging.getLogger(__name__)

ClientFactory = Callable[[Agent, Settings], AgentClient]

_default_client_factory: ClientFactory = client_for


@dataclass
class PollResult:
    agent_id: str
    agent_name: str
    metrics_written: int = 0
    # How many hosts GET /api/v1/hosts/overview reported beyond the polled
    # agent itself — 0 for a standalone/satellite agent, 1+ for a proxy
    # (Selecta) currently relaying one or more satellites (Duppies). See
    # docs/plan.md's monitoring-cockpit ergänzung Block F2.
    satellites_discovered: int = 0
    edges_written: int = 0
    errors: list[str] = field(default_factory=list)


async def _resolve_dst_agent_id(session: AsyncSession, dst_addr: str) -> uuid.UUID | None:
    """Best-effort: an agent's `address` is "host:port" of its own REST
    API, unrelated to whatever port a traced connection actually used —
    so this only matches on the host part. Not guaranteed to resolve
    every edge (an agent might not be enrolled, or reachable under a
    different name/IP than its edges report), which is why HostEdge's
    dst_agent_id column is nullable."""
    return await session.scalar(select(Agent.id).where(Agent.address.like(f"{dst_addr}:%")))


async def _series_id(
    session: AsyncSession, cache: dict[str, int], agent_id: uuid.UUID, metric: str, labels: dict
) -> int:
    """Resolve (or create) the metric_series row for one (agent, metric, labels)
    and return its series_id. `cache` is PER-CALL (per write, i.e. per
    transaction): the metric_series upsert and the metrics_raw insert that uses
    the returned id land in the SAME transaction, so they commit or roll back
    together. A module-global cache would survive a rollback and then point
    metrics_raw rows at a series_id whose metric_series row was never
    committed (FK violation / orphaned rows) — hence per-call only."""
    lj = json.dumps(labels or {}, sort_keys=True, separators=(",", ":"))
    key = metric + "\x00" + lj
    sid = cache.get(key)
    if sid is not None:
        return sid
    params = {"a": agent_id, "m": metric, "l": lj}
    # DO NOTHING (not DO UPDATE): an existing row must NOT be locked/updated —
    # DO UPDATE takes an exclusive row lock, and concurrent agent polls touching
    # overlapping series in different orders then deadlock. DO NOTHING returns
    # no row on conflict, so fall back to a plain SELECT for the existing id.
    row = await session.execute(
        text(
            """
            INSERT INTO metric_series (agent_id, metric, labels)
            VALUES (:a, :m, CAST(:l AS jsonb))
            ON CONFLICT (agent_id, metric, labels) DO NOTHING
            RETURNING series_id
            """
        ),
        params,
    )
    got = row.scalar_one_or_none()
    if got is None:
        got = (await session.execute(
            text(
                "SELECT series_id FROM metric_series "
                "WHERE agent_id = :a AND metric = :m AND labels = CAST(:l AS jsonb)"
            ),
            params,
        )).scalar_one()
    sid = int(got)
    cache[key] = sid
    return sid


async def _write_metrics(session: AsyncSession, agent_id: uuid.UUID, metrics: dict) -> int:
    cache: dict[str, int] = {}
    rows = []
    for metric_name, points in metrics.items():
        for point in points:
            sid = await _series_id(session, cache, agent_id, metric_name, point.get("labels") or {})
            rows.append({
                "time": datetime.fromisoformat(point["timestamp"]),
                "series_id": sid,
                "value": point["value"],
            })
    if not rows:
        return 0
    await _insert_metric_rows_chunked(session, rows)
    return len(rows)


# asyncpg caps a statement at 32767 bind parameters. metrics_raw rows have 3
# columns → ~10922 rows/INSERT; chunk well under that so a long catch-up write
# can't fail and wedge the cursor forever.
_METRIC_INSERT_CHUNK = 5000


async def _insert_metric_rows_chunked(session: AsyncSession, rows: list[dict]) -> None:
    # ON CONFLICT (series_id, time) DO NOTHING: re-polling an overlapping cursor
    # boundary repeats a point. With series_id there is no cross-label collision
    # (distinct labels = distinct series_id), so the old microsecond-nudge hack
    # is gone.
    for i in range(0, len(rows), _METRIC_INSERT_CHUNK):
        chunk = rows[i : i + _METRIC_INSERT_CHUNK]
        stmt = pg_insert(MetricRaw).values(chunk).on_conflict_do_nothing(
            index_elements=["series_id", "time"]
        )
        await session.execute(stmt)


async def _recorded_high_ports(
    session: AsyncSession, agent_id: uuid.UUID, edges: list[dict]
) -> dict[tuple[str, str], int]:
    """How many distinct high ports this agent ALREADY has recorded per (comm, addr).

    The fold's quorum has to be asked of everything ever seen, not of one dump: the agent forgets its own
    edges after 24h, so a slow churner reports two or three client ports at a time — under quorum, written
    individually, and the table accrues them one poll at a time. Measured after the batch-only rule shipped:
    kube-apiserver was back to 36 rows for one (comm, addr) within an hour.

    Asked only for the keys this dump actually has high ports for, so a host that talks to services only
    issues no query at all.
    """
    keys = set(high_ports_by_key(edges))
    if not keys:
        return {}
    rows = (await session.execute(
        select(HostEdge.src_comm, HostEdge.dst_addr, func.count(func.distinct(HostEdge.dst_port)))
        .where(HostEdge.src_agent_id == agent_id, HostEdge.dst_port >= EPHEMERAL_FLOOR)
        .group_by(HostEdge.src_comm, HostEdge.dst_addr)
    )).all()
    return {(comm, str(addr)): int(n) for comm, addr, n in rows if (comm, str(addr)) in keys}


async def _upsert_edges(session: AsyncSession, agent_id: uuid.UUID, edges: list[dict]) -> int:
    count = 0
    # A client port is not identity — fold the proven ones into one edge per (comm, addr) BEFORE the upsert,
    # so the table stops earning a permanent row per short-lived connection. See services/edge_identity.py
    # for the rule and the measurement; `GET /relationships` was already grouping these away at read time,
    # which is why 96.7% of 73 235 rows could accrue unnoticed.
    for e in collapse_client_ports(edges, await _recorded_high_ports(session, agent_id, edges)):
        dst_agent_id = await _resolve_dst_agent_id(session, e["dst_addr"])
        latency_ns = e.get("latency_ns")
        latency_ms = (latency_ns / 1_000_000) if latency_ns is not None else None

        stmt = pg_insert(HostEdge).values(
            src_agent_id=agent_id,
            src_comm=e["comm"],
            dst_addr=e["dst_addr"],
            dst_port=e["dst_port"],
            dst_agent_id=dst_agent_id,
            event_count=e["event_count"],
            first_seen_at=datetime.fromisoformat(e["first_seen"]),
            last_seen_at=datetime.fromisoformat(e["last_seen"]),
            # Only a single point estimate is available per edge from the
            # agent's dump (not a distribution) — stored as p50, p99 is
            # left NULL until the agent can report percentiles itself.
            latency_ms_p50=latency_ms,
        )
        stmt = stmt.on_conflict_do_update(
            index_elements=["src_agent_id", "src_comm", "dst_addr", "dst_port"],
            set_={
                "dst_agent_id": stmt.excluded.dst_agent_id,
                # event_count from the agent is already a lifetime
                # cumulative counter (see internal/store.UpsertEdge on the
                # Go side), not a delta for this poll window — overwrite,
                # don't add.
                "event_count": stmt.excluded.event_count,
                "last_seen_at": stmt.excluded.last_seen_at,
                "latency_ms_p50": stmt.excluded.latency_ms_p50,
            },
        )
        await session.execute(stmt)
        count += 1

        # The fold's CLAIM is that no member row exists — so enforce it instead of trusting that nothing
        # ever wrote one. Rows written before this rule shipped are the concrete case: a Bossman whose
        # migration ran six minutes before its new code did left 159 pre-fold rows for one (comm, addr),
        # frozen but still counted alongside the sentinel that now supersedes them. Without this they would
        # sit there until retention aged them out 30 days later, double-counting all the while. After the
        # first poll it is a no-op.
        if e.get("ports_collapsed"):
            await session.execute(
                delete(HostEdge).where(
                    HostEdge.src_agent_id == agent_id,
                    HostEdge.src_comm == e["comm"],
                    HostEdge.dst_addr == e["dst_addr"],
                    HostEdge.dst_port >= EPHEMERAL_FLOOR,
                )
            )
    return count


async def _write_snapshot_metrics(
    session: AsyncSession, agent_id: uuid.UUID, sample_time: datetime, metrics: list[dict]
) -> int:
    """Writes GET /api/v1/hosts/overview's flat `metrics` list (one latest
    value per series, no per-point timestamp) as Metric rows, all sharing
    sample_time — an approximation, not a real history (the existing
    GET /api/v1/metrics cursor-pull already covers real history for a
    directly-polled agent), but the only data Bossman ever gets for a
    satellite it cannot reach directly. Same ON CONFLICT DO NOTHING
    dedup as _write_metrics, for the identical reason (overlapping pulls
    can repeat the same (time, agent_id, metric) primary key)."""
    if not metrics:
        return 0
    cache: dict[str, int] = {}
    rows = []
    for m in metrics:
        sid = await _series_id(session, cache, agent_id, m["metric"], m.get("labels") or {})
        rows.append({"time": sample_time, "series_id": sid, "value": m["value"]})
    await _insert_metric_rows_chunked(session, rows)
    return len(rows)


async def _find_or_create_satellite(session: AsyncSession, name: str, parent_agent_id: uuid.UUID, mode: str, kind: str | None = None) -> Agent:
    """Finds or creates the Agent row for a satellite discovered via a
    proxy's own GET /api/v1/hosts/overview (see docs/plan.md's
    monitoring-cockpit ergänzung Block F2) — the fix for a satellite
    behind a proxy previously being invisible in Bossman entirely (its
    metrics silently merged onto the proxy's own agent row). A satellite
    row's `token`/`address` stay empty: Bossman never polls it directly,
    only ever relays its data through the proxy that already reached it —
    `poll_once`'s own `enrollment_state == "enrolled"` selection would
    otherwise also try to poll it directly and no-op (no address), which
    is harmless but the row's real name (agents.name is unique) must
    already exist before that no-op check runs, so this is called eagerly
    on every proxy poll, not lazily."""
    existing = await session.scalar(select(Agent).where(Agent.name == name))
    if existing is not None:
        if existing.parent_agent_id != parent_agent_id or existing.mode != mode:
            existing.parent_agent_id = parent_agent_id
            existing.mode = mode
        if kind and (existing.agent_metadata or {}).get("piggyback_kind") != kind:
            existing.agent_metadata = {**(existing.agent_metadata or {}), "piggyback_kind": kind}
        return existing

    satellite = Agent(
        name=name,
        token="",
        mode=mode,
        enrollment_state="enrolled",
        agent_metadata={"piggyback_kind": kind} if kind else {},
        parent_agent_id=parent_agent_id,
    )
    session.add(satellite)
    await session.flush()
    return satellite


async def _ingest_hosts_overview(
    session: AsyncSession, agent: Agent, hosts: list[dict], stale_after: timedelta | None = None
) -> int:
    """Ingests one GET /api/v1/hosts/overview response: the polled
    agent's own entry becomes agent-reported Services (its metrics
    already arrive via the existing full-history /api/v1/metrics pull, so
    only its checks are new information here); every other entry is a
    satellite relayed through this agent (a proxy) — discovered/updated
    as its own Agent row, its latest metrics written, its checks ingested,
    and Bossman's own check_rules evaluated against it exactly like any
    directly-enrolled host. Returns the number of satellite hosts found.
    Best-effort per host: one satellite's failure doesn't stop the rest
    from being ingested.

    The self entry is identified by an empty/absent `parent` field, NOT
    by `host == agent.name`: the Go agent reports its own OS hostname
    (os.Hostname()) as `host`, which need not match whatever name this
    agent was *enrolled* under in Bossman (an operator-chosen, arbitrary
    string — see internal/enroll's --name flag) — matching by name alone
    previously misfiled the proxy's own self entry as a bogus satellite
    of itself whenever the two names differed, confirmed against the real
    running stack before this fix."""
    now = datetime.now(timezone.utc)
    satellite_count = 0
    touched: list = []  # services touched this cycle, for post-commit notification dispatch

    for host in hosts:
        host_name = host.get("host")
        if not host_name:
            continue

        if not host.get("parent"):
            touched += await ingest_agent_checks(session, agent, host.get("checks") or [])
            _store_facts(agent, host, now)
            continue

        satellite_count += 1
        # agents.mode is an operational role (standalone|satellite|proxy). A
        # piggyback guest (container/proxmox/vsphere) is satellite-role from
        # Bossman's view; keep its real type in agent_metadata.piggyback_kind.
        # A relayed host is Bossman-managed, so it's a Duppy (satellite) or a
        # Selecta (proxy) — never "standalone" (that's an un-enrolled agent);
        # a self-reported "standalone" maps to satellite.
        raw_mode = host.get("mode") or "satellite"
        valid = raw_mode in ("satellite", "proxy")
        satellite = await _find_or_create_satellite(
            session, host_name, agent.id, raw_mode if valid else "satellite",
            kind=None if valid or raw_mode == "standalone" else raw_mode,
        )
        sample_time = now
        if host.get("last_sample_at"):
            try:
                sample_time = datetime.fromisoformat(host["last_sample_at"].replace("Z", "+00:00"))
            except ValueError:
                pass
        await _write_snapshot_metrics(session, satellite.id, sample_time, host.get("metrics") or [])
        touched += await ingest_agent_checks(session, satellite, host.get("checks") or [])
        _store_facts(satellite, host, now)
        satellite.last_seen_at = now
        # The proxy reports its satellites' agent versions if it knows them.
        relayed_version = str(host.get("version") or host.get("agent_version") or "")
        if relayed_version and relayed_version != satellite.agent_version:
            satellite.agent_version = relayed_version
        touched += await evaluate_host(session, satellite, stale_after=stale_after)
        # reached=None: Bossman never contacts a satellite directly, so freshness of the
        # relayed data is the only up/down signal there is. Without this a relay that
        # quietly stopped delivering was indistinguishable from a healthy host — and
        # `satellite.last_seen_at = now` above would even keep asserting it was fine,
        # because it records when the PROXY was polled, not when the satellite last
        # produced anything.
        touched.append(
            await update_host_alive(session, satellite, reached=None, now=now, stale_after=stale_after)
        )

    return satellite_count, touched


def _store_facts(agent: Agent, host: dict, now: datetime) -> None:
    """Persists the host's HW/SW inventory document from a hosts/overview
    entry (see the Go agent's internal/inventory, Block H1/H2). Only
    touches the row when the document actually changed — the inventory is
    near-static, and a no-op write per poll tick would just churn the
    table. `collected_at` is excluded from the comparison (the agent
    re-stamps it on every cache refresh even when nothing else moved).

    THIS FUNCTION OWNS THE INVENTORY KEYS AND NOTHING ELSE. `facts` is one document written by
    several producers — the inventory here, `installed_packages` from _collect_packages,
    `group_policy` from _refresh_group_policy, `external_audit_at` from the audit scan — so which
    keys belong to whom has to be explicit. It used to be an allowlist of two names, and that cost
    a real bug twice over: any key a *newer* producer added (a) made the change comparison compare
    the whole facts document against the inventory document, so it differed on every single tick,
    and (b) was dropped by the rewrite that followed. The visible symptom was `group_policy`
    silently disappearing between two polls and gpresult being re-read 8× in 25 minutes despite a
    six-hour throttle — the throttle stamp was in the key that kept vanishing.

    So the owned key set is RECORDED (`_inventory_keys`) instead of listed here: an inventory
    section that disappears is still dropped, and a fact this function has never heard of survives
    untouched. Adding a producer needs no edit here."""
    inv = host.get("inventory")
    if not isinstance(inv, dict) or not inv:
        return
    prev = agent.facts or {}
    owned = set(prev.get("_inventory_keys") or ()) | set(inv)
    # Compare inventory against inventory: what other producers put in `facts` is none of this
    # comparison's business. `collected_at` moves on every agent-side cache refresh.
    fresh = {k: v for k, v in inv.items() if k != "collected_at"}
    current = {k: prev.get(k) for k in fresh}
    vanished = {k for k in owned if k not in inv}  # a section the agent stopped reporting
    if fresh == current and not vanished:
        return
    merged = {k: v for k, v in prev.items() if k not in owned}
    merged.update(inv)
    merged["_inventory_keys"] = sorted(inv)
    agent.facts = merged
    agent.facts_updated_at = now


# How stale the cached observed-state document may get before the poller
# refreshes it. Config changes rarely, and the observed pull reads every config
# file on the host, so refreshing it every poll tick would be wasteful.
_OBSERVED_MAX_AGE = timedelta(minutes=15)


#: How stale the stored resultant policy may get. Group Policy changes on a gpupdate or a reboot, not by the
#: minute, and reading it costs a gpresult run (1.8 s measured) plus 48 kB of XML parsed on the host.
_GPRESULT_MAX_AGE = timedelta(hours=6)


async def _refresh_group_policy(session: AsyncSession, agent: Agent, client: AgentClient,
                                now: datetime) -> None:
    """Store the host's RESULTANT SET OF POLICY — what Windows Group Policy declares for this machine.

    A FOREIGN AUTHORITY'S INTENT, and that is why it is stored rather than merely readable on demand. We do
    not manage Group Policy (Windows keeps that, by the operator's decision), but where a GPO and our own
    declared config touch the same setting the GPO wins on the host and a convergence run fights it on every
    pass — forever, silently, with somebody watching a value revert and no explanation anywhere. The document
    has to carry the other authority's declaration for that conflict to be nameable at all.

    Windows hosts only, and asked for by FAMILY rather than by trying and failing: a Linux agent answers
    "no such tool" for windows_gpresult, and a poll cycle should not produce an error per Linux host per
    interval to learn something the inventory already said.
    """
    if (agent.facts or {}).get("os_family") != "windows":
        return

    stored = (agent.facts or {}).get("group_policy") or {}
    taken = stored.get("_taken_at")
    if taken:
        try:
            if now - datetime.fromisoformat(taken) < _GPRESULT_MAX_AGE:
                return
        except ValueError:
            pass  # an unparsable stamp is a reason to refresh, not to crash

    try:
        result = await client.call_tool("windows_gpresult", {"scope": "both"})
    except AgentClientError as exc:
        # Recorded, not raised: a host whose gpresult fails is still a host worth polling, and the reason
        # belongs where somebody will see it rather than in a log line that scrolls away.
        agent.facts = {**(agent.facts or {}),
                       "group_policy": {"_taken_at": now.isoformat(), "error": str(exc)}}
        agent.facts_updated_at = now
        return

    data = (result or {}).get("data") or {}
    agent.facts = {**(agent.facts or {}), "group_policy": {
        "_taken_at": now.isoformat(),
        # THE LABELS TRAVEL WITH THE DATA. Without them this section reads as something this system set, which
        # is the single misunderstanding that matters about it.
        "authority": data.get("authority", "windows-group-policy"),
        "managed_by_us": False,
        "read_at": data.get("read_at"),
        "som": data.get("computerresults_som"),
        "domain": data.get("computerresults_domain"),
        "slow_link": data.get("computerresults_slow_link"),
        "applied": data.get("applied") or [],
        # Denied GPOs are kept: "not in the applied list" and "refused for this host, here is why" are
        # different facts and only the second can be acted on.
        "denied": data.get("denied") or [],
        # WHAT SITS IN WINDOWS' POLICY TERRITORY — the 57 values in the Group-Policy-owned registry
        # subtrees. Named for what it is rather than for what one would wish it were: gpresult /X carries
        # no per-setting data on this host (measured), so this is the AREA's current content and not a
        # GPO's declaration, and the conflict report's wording depends on knowing the difference.
        # `settings` is the key the 0.1.x Windows agent used for the same read; accepted here so a
        # not-yet-updated agent keeps reporting, and dropped once no such agent is enrolled.
        "policy_area_values": data.get("policy_area_values") or data.get("settings") or [],
        "policy_area_source": registry_policy.IMPOSED_SOURCE_AREA,
    }}
    agent.facts_updated_at = now
    logger.info("group policy stored for %s: %d applied, %d denied, %d values in policy area",
                agent.name, len(data.get("applied") or []), len(data.get("denied") or []),
                len(data.get("policy_area_values") or data.get("settings") or []))


async def _refresh_observed_cache(session: AsyncSession, agent: Agent, client: AgentClient, now: datetime) -> None:
    """Upsert AgentObservedState (the server-as-a-document read) when the cache
    is missing or older than _OBSERVED_MAX_AGE, so GET /state/observed serves it
    from Postgres instantly instead of live-polling the agent per view open."""
    row = await session.get(AgentObservedState, agent.id)
    if row is not None and row.updated_at is not None and (now - row.updated_at) < _OBSERVED_MAX_AGE:
        return
    observed = await client.state_observed()
    if row is None:
        session.add(AgentObservedState(agent_id=agent.id, observed=observed, updated_at=now))
    else:
        row.observed = observed
        row.updated_at = now


async def _detect_config_drift(session: AsyncSession, agent: Agent, client: AgentClient) -> None:
    """DETECT config drift (per poll) and surface it as the "Config drift"
    monitoring service — WARN when a MANAGED file has been changed out of band.

    Deliberately REPORT-ONLY: the operator's rule is no automatic reconfiguration
    (man-in-the-middle safety). Nothing is re-applied here; the re-sync to desired
    is a manual, explicit action (the "Re-sync to desired" button on the host's
    Configuration tab). Best-effort; a failure here must never break the poll."""
    from bossman.services.config_desired import effective_resources
    from bossman.services.monitoring import CONFIG_DRIFT_SERVICE, DEFAULT_MAX_ATTEMPTS, _upsert_service_state

    async def _record_drift(n: int, detail: str) -> None:
        await _upsert_service_state(
            session, agent.id, CONFIG_DRIFT_SERVICE, "WARN" if n else "OK", float(n), detail,
            datetime.now(timezone.utc), DEFAULT_MAX_ATTEMPTS, metric="config_drift_files",
            rule_id=None, agent_name=agent.name, agent_tags=agent.tags, comparison="gt")

    eff = await effective_resources(session, agent)
    if not eff:
        await _record_drift(0, "no managed config on this host")
        return
    resources = [e["resource"] for e in eff]
    try:
        plan = await client.state_plan({"resources": resources})
    except AgentClientError:
        return
    changes = plan.get("changes", []) if isinstance(plan, dict) else []
    drifted = {c.get("path") for c in changes if c.get("action") not in (None, "noop") and not c.get("error")}
    await _record_drift(
        len(drifted),
        (f"{len(drifted)} managed config file(s) drifted from desired (manual re-sync required): "
         + ", ".join(sorted(str(p) for p in drifted))) if drifted
        else "all managed config files in sync with desired")
    if drifted:
        logger.info("config drift DETECTED on %s (report-only, manual re-sync): %d file(s): %s",
                    agent.name, len(drifted), ", ".join(sorted(str(p) for p in drifted)))


async def _collect_packages(agent: Agent, client: AgentClient, now: datetime) -> None:
    """Best-effort installed-package inventory (Debian dpkg via the agent's
    package_facts tool), stored on agent.facts["installed_packages"] so the
    desired-state document's inventory block lists them. Refreshed at most every
    6h and never allowed to break the poll cycle."""
    facts = agent.facts or {}
    last = facts.get("installed_packages_at")
    if last:
        try:
            if (now - datetime.fromisoformat(last)).total_seconds() < 21600:
                return
        except (ValueError, TypeError):
            pass
    try:
        res = await client.call_tool("package_facts", {})
    except Exception:  # noqa: BLE001 — best-effort, must not break the poll
        return
    pkgs = res.get("data") if isinstance(res, dict) else None
    if not isinstance(pkgs, list):
        return
    agent.facts = {**facts, "installed_packages": pkgs, "installed_packages_at": now.isoformat()}
    agent.facts_updated_at = now


async def _maybe_scan_external_audit(
    session: AsyncSession, agent: Agent, client: AgentClient, settings: Settings, now: datetime,
) -> None:
    """Opt-in out-of-band audit (BOSSMAN_EXTERNAL_AUDIT_ENABLED): install auditd
    watch rules on this host's managed config files and ingest any hand-edits into
    the audit trail. Throttled + best-effort — a host without auditd returns
    {available: false} and is simply skipped; nothing here may break the poll."""
    if not settings.external_audit_enabled:
        return
    facts = agent.facts or {}
    last = facts.get("external_audit_at")
    if last:
        try:
            if (now - datetime.fromisoformat(last)).total_seconds() < settings.external_audit_interval_seconds:
                return
        except (ValueError, TypeError):
            pass
    try:
        from bossman.services import external_audit
        from bossman.services.config_desired import effective_resources

        eff = await effective_resources(session, agent)
        paths = [e["path"] for e in eff if e.get("path")]
        if not paths:
            return
        await external_audit.scan_host(session, agent, client, paths)
    except Exception:  # noqa: BLE001 — never let drift-auditing break the poll cycle
        logger.exception("external audit scan failed for agent %s", agent.name)
        return
    agent.facts = {**(agent.facts or {}), "external_audit_at": now.isoformat()}


async def _poll_snmp_device(
    session: AsyncSession, device: Agent, settings: Settings, client_factory: ClientFactory,
) -> PollResult:
    """Block 3: poll one agent-less device (snmp or ssh) by running its assigned
    checks through its parent poller agent, with the device's connection params
    (snmp: target/community; ssh: target/user/password) merged into each check,
    and attributing the resulting Services to the device. The device row has no
    address/token — it exists so the device shows up as a monitored host."""
    result = PollResult(agent_id=str(device.id), agent_name=device.name)
    meta = device.agent_metadata or {}
    poller = await session.get(Agent, device.parent_agent_id) if device.parent_agent_id else None
    if poller is None or not poller.address:
        result.errors.append("no reachable poller agent for this device")
        return result

    kind = meta.get("kind", "snmp")
    extra: dict[str, str] = {}
    target = meta.get("target") or meta.get("snmp_target")
    if target:
        extra["target"] = str(target)
    if kind == "snmp":
        community = meta.get("community") or meta.get("snmp_community")
        if community:
            extra["community"] = str(community)
        # SNMP v3: pass the security params through so parameterize_snmp_star builds
        # the -v3/-l/-u/-a/-A/-x/-X/-n argv instead of the v2c -c community form.
        if (meta.get("snmp_version") or "v2c") == "v3":
            for k in ("snmp_version", "sec_level", "sec_name", "auth_proto",
                      "auth_pass", "priv_proto", "priv_pass", "context"):
                if meta.get(k):
                    extra[k] = str(meta[k])
    elif kind == "ssh":
        if meta.get("user"):
            extra["user"] = str(meta["user"])
        if meta.get("password"):
            extra["password"] = str(meta["password"])

    client = client_factory(poller, settings)
    now = datetime.now(timezone.utc)
    try:
        perf: list[dict] = []
        touched = await evaluate_assigned_checks(session, device, client, settings.checks_dir, extra_params=extra, perf_sink=perf)
        if perf:
            await _write_snapshot_metrics(session, device.id, now, perf)
        device.last_seen_at = now
        await session.commit()
        try:
            sent = await notification.collect_and_dispatch(session, settings, touched)
            if sent:
                await session.commit()
        except Exception:
            logger.exception("notification dispatch failed for SNMP device %s", device.name)
    except Exception as exc:  # noqa: BLE001 — one device must not sink the cycle
        logger.exception("SNMP device poll failed for %s", device.name)
        result.errors.append(f"snmp: {exc}")
    return result


async def poll_agent(
    session_factory: async_sessionmaker[AsyncSession],
    agent_id: uuid.UUID,
    settings: Settings,
    semaphore: asyncio.Semaphore,
    client_factory: ClientFactory = _default_client_factory,
) -> PollResult:
    async with semaphore, session_factory() as session:
        agent = await session.get(Agent, agent_id)
        if agent is None or agent.enrollment_state != "enrolled":
            return PollResult(agent_id=str(agent_id), agent_name=agent.name if agent else "?")

        # Block 3: an agent-less device (snmp/ssh) has no address of its own —
        # the co-located poller runs its checks on its behalf (connection params
        # from the device's metadata) and the Services attribute to the device.
        if (agent.agent_metadata or {}).get("kind") in ("snmp", "ssh"):
            return await _poll_snmp_device(session, agent, settings, client_factory)

        if not agent.address:
            return PollResult(agent_id=str(agent_id), agent_name=agent.name)

        result = PollResult(agent_id=str(agent.id), agent_name=agent.name)
        client = client_factory(agent, settings)
        now = datetime.now(timezone.utc)
        reached_agent = False
        # L1: how old a reading may be and still be judged. Derived from the poll
        # interval, so a deployment that polls every 10 minutes is not declared
        # stale by a 60-second assumption.
        stale_after = stale_after_for(settings)

        # The agent's build version, from its unauthenticated /healthz. Cheap, and
        # deliberately first: because it needs no token it still answers when the token
        # has drifted, which keeps "reachable but rejecting us" apart from "gone" in the
        # Host alive output. A failure here is not itself evidence of unreachability —
        # the real data pulls below decide that.
        try:
            health = await client.healthz()
            observed = str(health.get("version") or "")
            if observed and observed != agent.agent_version:
                agent.agent_version = observed
        except AgentClientError as exc:
            logger.debug("healthz failed for agent %s: %s", agent.name, exc)

        try:
            metrics = await client.metrics_dump(agent.last_metrics_pulled_at)
            result.metrics_written = await _write_metrics(session, agent.id, metrics)
            agent.last_metrics_pulled_at = now
            reached_agent = True
        except AgentClientError as exc:
            result.errors.append(f"metrics: {exc}")

        try:
            edges = await client.connections_dump(agent.last_edges_pulled_at)
            result.edges_written = await _upsert_edges(session, agent.id, edges)
            agent.last_edges_pulled_at = now
            reached_agent = True
        except AgentClientError as exc:
            result.errors.append(f"edges: {exc}")

        touched: list = []  # services touched this cycle → post-commit notification dispatch
        try:
            hosts = await client.hosts_overview()
            result.satellites_discovered, ingest_touched = await _ingest_hosts_overview(
                session, agent, hosts, stale_after=stale_after
            )
            touched += ingest_touched
            reached_agent = True
            # A Bossman-managed agent is never "standalone" — that's an
            # un-enrolled agent running on its own (bearer-only, no Bossman).
            # Once we reach it, it's a Selecta (proxy) if it fronts satellites,
            # else a Duppy (satellite role). Only set when hosts_overview
            # succeeded, so a transient failure can't flip a proxy to duppy.
            # The infra poller keeps its fixed proxy/"selecta" role (it fronts
            # agent-less devices, not hosts/overview satellites) — don't downgrade.
            if not is_infra_agent(agent):
                agent.mode = "proxy" if result.satellites_discovered > 0 else "satellite"
        except AgentClientError as exc:
            result.errors.append(f"hosts_overview: {exc}")

        if reached_agent:
            agent.last_seen_at = now

        # L2: the host's reachability is itself a monitored service — CRIT when it does
        # not answer, unless a downtime says that is expected. Recorded BEFORE
        # evaluate_host so that L3 can already see a confirmed-down host when this
        # cycle's service notifications are dispatched.
        try:
            touched.append(
                await update_host_alive(
                    session,
                    agent,
                    reached=reached_agent,
                    now=now,
                    stale_after=stale_after,
                    detail="; ".join(result.errors),
                )
            )
        except Exception:
            logger.exception("update_host_alive failed for agent %s", agent.name)

        # Runs regardless of whether this cycle's metrics pull succeeded —
        # a transient pull failure shouldn't also freeze monitoring state
        # evaluation against whatever value is already stored. Isolated in
        # its own try/except so one host's evaluation bug can't crash the
        # whole poll cycle (mirrors the metrics/edges try/except above).
        try:
            touched += await evaluate_host(session, agent, stale_after=stale_after)
            # Lapse any timed acknowledgements that have expired (Block H5),
            # so a problem resurfaces on the next poll even with no UI open.
            await expire_acknowledgements(session, now)
        except Exception:
            logger.exception("evaluate_host failed for agent %s", agent.name)

        # Run the host's ASSIGNED Starlark checks (sshd_config etc.) and turn
        # each into a Service — needs the live agent client, so only when we
        # reached it this cycle. Isolated so an execution bug can't crash the
        # poll cycle.
        if reached_agent:
            try:
                perf: list[dict] = []
                touched += await evaluate_assigned_checks(session, agent, client, settings.checks_dir, perf_sink=perf)
                if perf:
                    await _write_snapshot_metrics(session, agent.id, now, perf)
            except Exception:
                logger.exception("evaluate_assigned_checks failed for agent %s", agent.name)
            # Inventory: refresh the installed-package list (throttled, best-effort).
            if not is_infra_agent(agent):
                await _collect_packages(agent, client, now)
            # Config drift DETECTION (report-only): surface drifted MANAGED config
            # as the "Config drift" service. No automatic reconfiguration — re-sync
            # is a manual operator action. Isolated so it can't crash the poll cycle.
            if not is_infra_agent(agent):
                try:
                    await _detect_config_drift(session, agent, client)
                except Exception:
                    logger.exception("config drift detection crashed for agent %s", agent.name)
                # Cache the observed-state document (server-as-a-document) so the
                # Configuration view loads from Postgres, not a slow live
                # pass-through on every open. Throttled — config changes rarely,
                # and the UI Reload button forces a fresh fetch on demand.
                try:
                    await _refresh_observed_cache(session, agent, client, now)
                except Exception:
                    logger.exception("observed-state cache refresh failed for agent %s", agent.name)
                # The RESULTANT SET OF POLICY — Windows' own declaration for this host. Own try/except and
                # its own throttle: a gpresult that fails must not cost the observed-state cache, and vice
                # versa.
                try:
                    await _refresh_group_policy(session, agent, client, now)
                except Exception:
                    logger.exception("group policy refresh failed for agent %s", agent.name)
                # Out-of-band (drift) audit via auditd — opt-in, throttled, best-effort.
                await _maybe_scan_external_audit(session, agent, client, settings, now)

        await session.commit()

        # Notifications (Block H8): dispatch AFTER the state commit so the
        # network I/O (SMTP/webhook) never holds the DB transaction, and a
        # send failure can't roll back monitoring state. Best-effort;
        # collect_and_dispatch applies its own ack/downtime/flapping
        # suppression and logs every send. The `_notify_event` markers live
        # on the in-memory Service objects (expire_on_commit=False).
        try:
            sent = await notification.collect_and_dispatch(session, settings, touched)
            if sent:
                await session.commit()
        except Exception:
            logger.exception("notification dispatch failed for agent %s", agent.name)

        # Event-driven self-healing — AUTOMATIC event handling only: a check that
        # just went hard records a PENDING remediation proposal for each matching
        # policy. Nothing runs automatically; an operator/AI applies it.
        if settings.remediation_enabled:
            try:
                from bossman.services import remediation

                proposed = await remediation.collect_and_propose(session, touched)
                if proposed:
                    await session.commit()
            except Exception:
                logger.exception("remediation proposal failed for agent %s", agent.name)
        return result


async def poll_once(
    session_factory: async_sessionmaker[AsyncSession],
    settings: Settings,
    client_factory: ClientFactory = _default_client_factory,
) -> list[PollResult]:
    """Runs one full poll cycle over every enrolled agent, bounded to
    settings.poll_concurrency in flight at a time. client_factory exists
    solely so tests can substitute a fake AgentClient instead of a real
    one — mirrors the Go proxy's own Manager.pullerFactory test seam
    (internal/fleet/manager.go)."""
    async with session_factory() as session:
        agent_ids = (await session.scalars(select(Agent.id).where(Agent.enrollment_state == "enrolled"))).all()

    if not agent_ids:
        return []

    semaphore = asyncio.Semaphore(settings.poll_concurrency)
    results = await asyncio.gather(
        *(poll_agent(session_factory, aid, settings, semaphore, client_factory) for aid in agent_ids)
    )

    # C1/C2: cluster aggregation runs ONCE per cycle and AFTER every node — an aggregate
    # built from half-fresh node states would flap on nothing but poll ordering. Its own
    # session/commit so a clustering bug cannot roll back the cycle's monitoring state, and
    # its touched services go through the normal notification dispatch (a cluster is a
    # host; its services are services).
    try:
        async with session_factory() as session:
            from bossman.services.clustering import aggregate_all_clusters

            clustered = await aggregate_all_clusters(session)
            if clustered:
                await session.commit()
                sent = await notification.collect_and_dispatch(session, settings, clustered)
                if sent:
                    await session.commit()
    except Exception:  # noqa: BLE001 — clustering must never crash the poll cycle
        logger.exception("cluster aggregation failed")

    # On-call escalation runs ONCE per cycle (not per agent): fire delayed
    # notification rules for problems that are still unacked past their delay.
    try:
        async with session_factory() as session:
            escalated = await notification.dispatch_escalations(session, settings)
            if escalated:
                await session.commit()
    except Exception:  # noqa: BLE001 — escalation must never crash the poll cycle
        logger.exception("escalation dispatch failed")

    return list(results)


@dataclass
class PollerStats:
    """Last-cycle outcome, surfaced by GET /api/v1/admin/diagnostics
    (Block K2) — the closest yolo-man equivalent to Zabbix's queue/value-
    cache diagnostics, since Bossman has no persistent queue of its own
    (each cycle just walks every enrolled agent)."""

    last_run_at: datetime | None = None
    last_run_duration_ms: float | None = None
    agents_polled: int = 0
    agents_with_errors: int = 0


async def poller_loop(
    session_factory: async_sessionmaker[AsyncSession],
    settings: Settings,
    stop_event: asyncio.Event,
    stats: PollerStats | None = None,
) -> None:
    """Runs poll_once on settings.poll_interval_seconds until stop_event is
    set — the long-lived background task started from bossman.main's
    lifespan. Skips actual polling entirely while settings.poll_enabled is
    False (mirrors housekeeping_loop's own settings.housekeeping_enabled
    guard) — disabled in the test suite, see config.py's poll_enabled."""
    while not stop_event.is_set():
        if settings.poll_enabled:
            started = datetime.now(timezone.utc)
            try:
                # Check the agent release channel (throttled to its own interval
                # inside maybe_refresh) so "a newer package is on GitHub" is known
                # without a separate loop. Never blocks the poll cycle materially.
                try:
                    await agent_release.maybe_refresh(settings)
                except Exception:  # noqa: BLE001
                    logger.debug("agent-release check skipped", exc_info=True)
                # Rebuild the infra knowledge index (throttled inside; incremental
                # + degrades to text-only when no embed endpoint is present).
                try:
                    await knowledge_index.maybe_reindex(session_factory, settings)
                except Exception:  # noqa: BLE001
                    logger.debug("knowledge reindex skipped", exc_info=True)
                # Closed-loop VERIFY: check whether applied remediations actually
                # recovered their trigger, and escalate the ones that didn't.
                if settings.remediation_enabled:
                    try:
                        from bossman.services import remediation
                        # Autonomy (Phase 2): apply eligible pending proposals
                        # unattended — self-gated by the kill-switch + guardrails.
                        await remediation.auto_apply_due(session_factory, settings)
                        await remediation.verify_due(session_factory, settings)
                    except Exception:  # noqa: BLE001
                        logger.debug("remediation auto-apply/verify skipped", exc_info=True)
                results = await poll_once(session_factory, settings)
                failed = [r for r in results if r.errors]
                if failed:
                    logger.warning("poll cycle: %d/%d agents had errors: %s", len(failed), len(results), failed)
                if stats is not None:
                    stats.last_run_at = started
                    stats.last_run_duration_ms = (datetime.now(timezone.utc) - started).total_seconds() * 1000
                    stats.agents_polled = len(results)
                    stats.agents_with_errors = len(failed)
            except Exception:
                logger.exception("poll cycle failed unexpectedly")

        try:
            await asyncio.wait_for(stop_event.wait(), timeout=settings.poll_interval_seconds)
        except TimeoutError:
            pass
