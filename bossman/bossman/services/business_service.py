"""Business / logical service aggregation (gap #4): roll a single state up from
many underlying per-host services across the fleet.

A BusinessService has `members` (a list of selectors, each a scope + optional
service-name filter) that expand to a set of Service rows, and `logic`:
  * all — AND / worst-of: the business service is only OK when every member is OK
    (a component failing drags it down). The classic "Webshop = web AND db".
  * any — OR / best-of: OK if at least one member is OK (redundancy pools); CRIT
    only when all members are CRIT.
Soft (unconfirmed) non-OK states are treated as OK, matching the problems view.
A worsening/recovering transition dispatches a NotifyEvent.
"""

from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timezone

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from bossman.config import Settings
from bossman.db.models import BusinessService, Service
from bossman.services import notification
from bossman.services.check_assignments import filter_agent_ids
from bossman.services.compiler import affected_agent_ids

logger = logging.getLogger(__name__)

# Worst-wins severity (matches monitoring._STATE_SEVERITY): UNKNOWN ranks below CRIT.
_SEVERITY = {"OK": 0, "WARN": 1, "UNKNOWN": 2, "CRIT": 3}
_BY_RANK = {v: k for k, v in _SEVERITY.items()}


def rollup(states: list[str], logic: str) -> str:
    """Combine member states into one. `all` = worst-of (AND); `any` = best-of
    (OR/redundancy). Empty set → UNKNOWN."""
    ranks = [_SEVERITY.get(s, 2) for s in states]
    if not ranks:
        return "UNKNOWN"
    return _BY_RANK[max(ranks)] if logic == "all" else _BY_RANK[min(ranks)]


def _effective_state(svc: Service) -> str:
    """A soft non-OK state hasn't been confirmed — count it as OK for roll-up."""
    if svc.state != "OK" and svc.state_type != "hard":
        return "OK"
    return svc.state


async def _matched_services(session: AsyncSession, bs: BusinessService) -> list[Service]:
    """Expand a business service's member selectors into the matching Service
    rows (deduped by service id)."""
    seen: dict = {}
    for sel in bs.members or []:
        scope_type = sel.get("scope_type", "global")
        agent_ids = await affected_agent_ids(
            session, scope_type,
            ou_id=sel.get("ou_id"), agent_id=sel.get("agent_id"),
            host_group_id=sel.get("host_group_id"), tenant_id=bs.tenant_id,
        )
        # The service's condition applies to every one of its selectors: it says which hosts belong to
        # this business service at all, not which ones a particular selector happens to pick. Applying
        # it per selector would be the same answer with more chances to forget one.
        agent_ids = await filter_agent_ids(session, list(agent_ids), getattr(bs, "conditions", None))
        if not agent_ids:
            continue
        stmt = select(Service).where(Service.agent_id.in_(agent_ids))
        name = (sel.get("service_name") or "").strip()
        if name:
            stmt = stmt.where(Service.name.ilike(f"%{name}%"))
        for svc in (await session.scalars(stmt)).all():
            seen[svc.id] = svc
    return list(seen.values())


async def evaluate_business_service(session: AsyncSession, settings: Settings, bs: BusinessService, *, commit: bool = True) -> dict:
    """Recompute one business service's rolled-up state, persist status + a
    per-member summary, and alert on a worsening/recovering transition."""
    old_status = bs.status
    services = await _matched_services(session, bs)
    members = [
        {"host": None, "service": s.name, "agent_id": str(s.agent_id), "state": _effective_state(s)}
        for s in services
    ]
    states = [m["state"] for m in members]
    new_status = rollup(states, bs.logic)
    counts: dict[str, int] = {}
    for st in states:
        counts[st] = counts.get(st, 0) + 1

    bs.status = new_status
    bs.summary = {"member_count": len(members), "counts": counts, "members": members[:200]}
    bs.last_evaluated_at = datetime.now(timezone.utc)

    old_rank, new_rank = _SEVERITY.get(old_status, 2), _SEVERITY.get(new_status, 2)
    if new_rank != old_rank and old_status != "UNKNOWN":
        worse = new_rank > old_rank
        detail = f"{new_status} ({counts.get('CRIT', 0)} CRIT, {counts.get('WARN', 0)} WARN of {len(members)})"
        if worse and new_status in ("WARN", "CRIT"):
            await notification.dispatch(session, settings, notification.NotifyEvent(
                agent_name=bs.name, service_name=f"Business service: {bs.name}",
                state=new_status, event="problem", output=detail,
            ))
        elif new_status == "OK":
            await notification.dispatch(session, settings, notification.NotifyEvent(
                agent_name=bs.name, service_name=f"Business service: {bs.name}",
                state="OK", event="recovery", output=detail,
            ))
    if commit:
        await session.commit()
    return {"name": bs.name, "status": new_status, "members": len(members)}


async def evaluate_all(session: AsyncSession, settings: Settings, tenant_id=None) -> list[dict]:
    stmt = select(BusinessService).where(BusinessService.enabled.is_(True))
    if tenant_id is not None:
        stmt = stmt.where(BusinessService.tenant_id == tenant_id)
    rows = (await session.scalars(stmt)).all()
    results = [await evaluate_business_service(session, settings, bs, commit=False) for bs in rows]
    await session.commit()
    return results


async def business_service_loop(
    session_factory: async_sessionmaker[AsyncSession], settings: Settings, stop_event
) -> None:
    """Periodically recompute all business services. Guarded by
    settings.business_service_enabled; interval business_service_interval_seconds."""
    if not settings.business_service_enabled:
        return
    interval = max(30, settings.business_service_interval_seconds)
    while not stop_event.is_set():
        try:
            async with session_factory() as session:
                rows = (await session.scalars(
                    select(BusinessService).where(BusinessService.enabled.is_(True))
                )).all()
                for bs in rows:
                    await evaluate_business_service(session, settings, bs, commit=False)
                await session.commit()
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001
            logger.exception("business-service recompute cycle failed")
        try:
            await asyncio.wait_for(stop_event.wait(), timeout=interval)
        except asyncio.TimeoutError:
            pass
