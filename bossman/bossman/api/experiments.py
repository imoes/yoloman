"""Tuning experiments over REST — the same implementation as the MCP tools experiment_start, experiment_status and
experiments (services/experiment.py, docs/kernel-tuning.md block 5)."""
from __future__ import annotations

from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity, require_manage_agent
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.models import Agent
from bossman.db.session import get_session

router = APIRouter()


class ExperimentIn(BaseModel):
    tunable: str
    params: dict[str, Any]
    profile: str
    runs: int = 5
    hypothesis: str = ""
    snapshot: bool = False


@router.post("/api/v1/agents/{agent_id}/experiments", status_code=202)
async def start_experiment(agent_id: UUID, body: ExperimentIn, request: Request,
                           session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
                           client_factory=Depends(get_client_factory), identity=Depends(require_manage_agent)) -> dict[str, Any]:
    from bossman.services import experiment as ex

    agent = await session.get(Agent, agent_id)
    if agent is None:
        raise HTTPException(status_code=404, detail="no such host")
    try:
        return await ex.start(session, agent=agent, tunable=body.tunable, params=body.params, profile=body.profile,
                              runs=body.runs, hypothesis=body.hypothesis,
                              requested_by=getattr(identity, "name", None) or "rest",
                              session_factory=request.app.state.session_factory, settings=settings,
                              client_factory=client_factory, snapshot=body.snapshot)
    except ex.ExperimentError as exc:
        raise HTTPException(status_code=exc.status, detail=str(exc)) from exc


@router.get("/api/v1/agents/{agent_id}/experiments")
async def list_experiments(agent_id: UUID, limit: int = 20, session: AsyncSession = Depends(get_session),
                           _identity=Depends(get_current_identity)) -> list[dict[str, Any]]:
    from bossman.services import experiment as ex

    agent = await session.get(Agent, agent_id)
    if agent is None:
        raise HTTPException(status_code=404, detail="no such host")
    return await ex.list_for(session, agent, limit=max(1, min(limit, 200)))


@router.get("/api/v1/experiments/{experiment_id}")
async def experiment_status(experiment_id: str, wait_s: int = 0, session: AsyncSession = Depends(get_session),
                            _identity=Depends(get_current_identity)) -> dict[str, Any]:
    from bossman.services import experiment as ex

    try:
        return await ex.status(session, experiment_id, wait_s=wait_s)
    except ex.ExperimentError as exc:
        raise HTTPException(status_code=exc.status, detail=str(exc)) from exc
