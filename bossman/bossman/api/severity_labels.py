"""Severity labels (Zabbix gap-analysis Block K10): display-only label/
color override per state. Cosmetic — the 4-value state machine itself
(OK/WARN/CRIT/UNKNOWN) is unchanged; this only lets an operator rename/
recolor how a state is shown (e.g. WARN -> "Degraded"), the narrower
equivalent of Zabbix's fully free-text severities.

Rows are seeded once by the migration (one per state) and never created/
deleted here — only GET (list all 4) and PUT (update one state's label/
color) are exposed.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.db.models import SeverityLabel
from bossman.db.session import get_session

router = APIRouter()

_STATES = ("OK", "WARN", "CRIT", "UNKNOWN")


class SeverityLabelOut(BaseModel):
    state: str
    label: str
    color: str

    @classmethod
    def from_model(cls, s: SeverityLabel) -> "SeverityLabelOut":
        return cls(state=s.state, label=s.label, color=s.color)


class SeverityLabelUpdate(BaseModel):
    label: str
    color: str


@router.get("/api/v1/severity-labels", response_model=list[SeverityLabelOut])
async def list_severity_labels(
    session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> list[SeverityLabelOut]:
    rows = (await session.scalars(select(SeverityLabel))).all()
    return [SeverityLabelOut.from_model(r) for r in rows]


@router.put("/api/v1/severity-labels/{state}", response_model=SeverityLabelOut)
async def update_severity_label(
    state: str,
    body: SeverityLabelUpdate,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> SeverityLabelOut:
    if state not in _STATES:
        raise HTTPException(status_code=422, detail=f"state must be one of {_STATES}")
    if not body.label.strip():
        raise HTTPException(status_code=422, detail="label is required")
    row = await session.get(SeverityLabel, state)
    if row is None:
        raise HTTPException(status_code=404, detail=f"no severity label seeded for state {state!r}")
    row.label = body.label
    row.color = body.color
    await session.commit()
    return SeverityLabelOut.from_model(row)
