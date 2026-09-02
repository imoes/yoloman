"""L4: time periods — reusable "when" objects for notification rules.

A period is weekday ranges + date exceptions + excluded periods; the evaluator lives in
services/time_periods.py (ported from Checkmk's is_timeperiod_active). This module is only
the CRUD surface plus the validation that keeps a stored period evaluable:

- definitions are validated on write, not on use. A "tuseday" typo or a 22:00-02:00 span
  would otherwise sit in the database as a window that silently never matches — and the
  place it goes wrong is the notification path, where the symptom is a missing page.
- `excludes` names other periods, as in Checkmk. Deleting or renaming a period another one
  references is refused, because a dangling exclude makes the referencing period
  unevaluable (and the dispatcher then treats it as unrestricted, i.e. the exclusion
  quietly stops applying).
- built-ins (24x7) cannot be deleted or renamed.

`GET .../active` answers "is it active right now", which is what makes the feature
debuggable — "why did nobody get paged" needs an answer that is not a code read.
"""

from __future__ import annotations

from datetime import datetime, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.api.etag import check_if_match, compute_version
from bossman.config import get_settings
from bossman.db.models import NotificationRule, TimePeriod
from bossman.db.session import get_session
from bossman.services import time_periods as tp

router = APIRouter()


class TimePeriodIn(BaseModel):
    name: str
    alias: str = ""
    # {"monday": [["08:00", "17:00"]], ...}
    ranges: dict[str, list[list[str]]] = {}
    # {"2026-12-24": []} — empty list = closed all day
    exceptions: dict[str, list[list[str]]] = {}
    # names of periods that deactivate this one while they are active
    excludes: list[str] = []


class TimePeriodOut(TimePeriodIn):
    id: UUID
    is_builtin: bool
    created_at: datetime
    # Convenience for the UI: whether the period is active at the moment of the request,
    # and in WHICH clock — a window read in the wrong zone is off by the local offset and
    # that is invisible from the definition alone.
    active_now: bool
    timezone: str = ""
    # A3: send this back in If-Match on PUT — see api/etag.py. active_now/timezone are
    # deliberately NOT part of it: they move with the clock, and a version that changes on
    # its own would reject every save with a conflict nobody caused.
    version: str = ""

    @classmethod
    def from_model(cls, p: TimePeriod, *, active_now: bool, timezone: str = "") -> "TimePeriodOut":
        return cls(
            id=p.id, name=p.name, alias=p.alias, ranges=p.ranges or {},
            exceptions=p.exceptions or {}, excludes=list(p.excludes or []),
            is_builtin=p.is_builtin, created_at=p.created_at, active_now=active_now,
            timezone=timezone,
        )

    def with_version(self) -> "TimePeriodOut":
        self.version = compute_version(self)
        return self


async def _all_specs(session: AsyncSession) -> dict[str, dict]:
    rows = (await session.scalars(select(TimePeriod))).all()
    return {
        r.name: {"alias": r.alias, "ranges": r.ranges or {}, "exceptions": r.exceptions or {}, "excludes": list(r.excludes or [])}
        for r in rows
    }


def _active(name: str, specs: dict[str, dict], when: datetime) -> bool:
    """Never raises: a period that cannot be evaluated is reported as inactive here.

    The dispatcher deliberately treats the same situation as *unrestricted* (better a page
    at the wrong hour than no page). Listing is a different question — "is this definition
    working" — so an unevaluable one must not claim to be active.
    """
    zone = tp.resolve_zone(get_settings().time_period_timezone)
    try:
        return tp.is_active(name, when, specs, zone=zone)
    except tp.TimePeriodError:
        return False


async def _validate(body: TimePeriodIn, session: AsyncSession, *, current: TimePeriod | None = None) -> None:
    name = body.name.strip()
    if not name:
        raise HTTPException(status_code=422, detail="name is required")
    try:
        tp.normalise_ranges(body.ranges)
        tp.normalise_exceptions(body.exceptions)
    except tp.TimePeriodError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    clash = await session.scalar(select(TimePeriod).where(TimePeriod.name == name))
    if clash is not None and (current is None or clash.id != current.id):
        raise HTTPException(status_code=409, detail=f"a time period named {name!r} already exists")

    known = set(await _all_specs(session)) | {tp.ALWAYS, name}
    for excluded in body.excludes:
        if excluded not in known:
            raise HTTPException(status_code=422, detail=f"excludes unknown time period {excluded!r}")
        if excluded == name:
            raise HTTPException(status_code=422, detail="a time period cannot exclude itself")


async def _referencing(session: AsyncSession, name: str) -> list[str]:
    """Which other periods exclude this one (by name)."""
    rows = (await session.scalars(select(TimePeriod))).all()
    return [r.name for r in rows if name in (r.excludes or [])]


@router.get("/api/v1/time-periods", response_model=list[TimePeriodOut])
async def list_time_periods(
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> list[TimePeriodOut]:
    """Reusable "when" objects — the named windows notification rules refer to.

    A period is weekday ranges plus date exceptions plus excluded periods. Naming it once and
    referring to it beats repeating "Mon-Fri 08:00-18:00" in every rule, which is how two rules end
    up disagreeing about business hours.
    """
    specs = await _all_specs(session)
    zone_name = get_settings().time_period_timezone
    now = datetime.now(timezone.utc)
    rows = (await session.scalars(select(TimePeriod).order_by(TimePeriod.name))).all()
    return [
        TimePeriodOut.from_model(p, active_now=_active(p.name, specs, now), timezone=zone_name).with_version()
        for p in rows
    ]


@router.post("/api/v1/time-periods", response_model=TimePeriodOut, status_code=201)
async def create_time_period(
    body: TimePeriodIn,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> TimePeriodOut:
    """Create a time period. **The definition is validated on write, not on use.**

    A `tuseday` typo or a malformed span is refused here with the reason. The alternative is a stored
    period that silently never matches — and a notification that never fires is the hardest failure
    to notice, because nothing appears.

    A span crossing midnight (22:00-02:00) is accepted and understood as crossing; it is not a
    mistake.
    """
    await _validate(body, session)
    period = TimePeriod(
        name=body.name.strip(), alias=body.alias,
        ranges=tp.normalise_ranges(body.ranges),
        exceptions=tp.normalise_exceptions(body.exceptions),
        excludes=list(body.excludes),
    )
    session.add(period)
    await session.commit()
    specs = await _all_specs(session)
    return TimePeriodOut.from_model(
        period,
        active_now=_active(period.name, specs, datetime.now(timezone.utc)),
        timezone=get_settings().time_period_timezone,
    ).with_version()


@router.put("/api/v1/time-periods/{period_id}", response_model=TimePeriodOut)
async def update_time_period(
    period_id: UUID,
    body: TimePeriodIn,
    request: Request,
    response: Response,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> TimePeriodOut:
    """Replace a period's definition, validated as on create.

    Rules referring to it change behaviour immediately — that is the point of a shared object, and
    the reason to check who refers to it before widening a window.
    """
    period = await session.get(TimePeriod, period_id)
    if period is None:
        raise HTTPException(status_code=404, detail="no such time period")
    check_if_match(request, TimePeriodOut.from_model(period, active_now=False).with_version().version)
    await _validate(body, session, current=period)
    new_name = body.name.strip()
    if new_name != period.name:
        if period.is_builtin:
            raise HTTPException(status_code=409, detail="a built-in time period cannot be renamed")
        if referrers := await _referencing(session, period.name):
            # excludes reference by name, so a rename would dangle them.
            raise HTTPException(
                status_code=409,
                detail=f"cannot rename: excluded by {', '.join(sorted(referrers))}",
            )
    period.name = new_name
    period.alias = body.alias
    period.ranges = tp.normalise_ranges(body.ranges)
    period.exceptions = tp.normalise_exceptions(body.exceptions)
    period.excludes = list(body.excludes)
    await session.commit()
    specs = await _all_specs(session)
    return TimePeriodOut.from_model(
        period,
        active_now=_active(period.name, specs, datetime.now(timezone.utc)),
        timezone=get_settings().time_period_timezone,
    ).with_version()


@router.delete("/api/v1/time-periods/{period_id}", status_code=204)
async def delete_time_period(
    period_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> None:
    """Delete a time period.

    A notification rule pointing at a period that no longer exists loses its window — check what
    refers to it first, since this call cannot see those references.
    """
    period = await session.get(TimePeriod, period_id)
    if period is None:
        raise HTTPException(status_code=404, detail="no such time period")
    if period.is_builtin:
        raise HTTPException(status_code=409, detail="a built-in time period cannot be deleted")
    if referrers := await _referencing(session, period.name):
        raise HTTPException(status_code=409, detail=f"still excluded by {', '.join(sorted(referrers))}")
    # Rules pointing at it are widened back to "always" by the FK's ON DELETE SET NULL —
    # deliberately, because the alternative (refusing, or cascading) either blocks cleanup
    # or silently deletes someone's alerting.
    await session.delete(period)
    await session.commit()


@router.get("/api/v1/time-periods/{period_id}/usage")
async def time_period_usage(
    period_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict:
    """What would be affected by changing this window — asked before editing, not after."""
    period = await session.get(TimePeriod, period_id)
    if period is None:
        raise HTTPException(status_code=404, detail="no such time period")
    rules = (
        await session.scalars(select(NotificationRule).where(NotificationRule.time_period_id == period_id))
    ).all()
    specs = await _all_specs(session)
    return {
        "id": str(period.id),
        "name": period.name,
        "active_now": _active(period.name, specs, datetime.now(timezone.utc)),
        "timezone": get_settings().time_period_timezone,
        "notification_rules": [{"id": str(r.id), "name": r.name, "enabled": r.enabled} for r in rules],
        "excluded_by": sorted(await _referencing(session, period.name)),
    }
