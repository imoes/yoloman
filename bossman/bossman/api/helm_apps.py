"""Helm/K8s app target endpoints (app-system increment 3) — the App-Store k8s
tier: available charts (search) + their values (from the chart) + deployed
releases (helm list) + preview (helm template). See services/helm_app.py."""
from __future__ import annotations

from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import require_manage_agent
from bossman.api.management import _agent_with_address
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.session import get_session
from bossman.services import helm_app

router = APIRouter()


class AddRepoBody(BaseModel):
    name: str
    url: str


class RenderBody(BaseModel):
    name: str
    chart: str
    values_yaml: str = ""
    values: dict[str, Any] | None = None  # flat dotted-key form values (→ YAML)
    namespace: str = "default"


class InstallBody(BaseModel):
    name: str
    chart: str
    values_yaml: str = ""
    values: dict[str, Any] | None = None  # flat dotted-key form values (→ YAML)
    namespace: str = "default"
    create_namespace: bool = True
    wait: bool = False


class RollbackBody(BaseModel):
    name: str
    revision: int | None = None
    namespace: str = "default"


class UninstallBody(BaseModel):
    name: str
    namespace: str = "default"


def _deps():
    return (
        Depends(get_session), Depends(get_settings),
        Depends(require_manage_agent), Depends(get_client_factory),
    )


@router.get("/api/v1/agents/{agent_id}/helm/releases")
async def helm_releases(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Deployed k8s releases (helm list -A) — what's running on the cluster."""
    agent = await _agent_with_address(session, agent_id)
    return await helm_app.list_releases(agent, client_factory, settings)


@router.get("/api/v1/agents/{agent_id}/helm/repos")
async def helm_repos(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    agent = await _agent_with_address(session, agent_id)
    return await helm_app.list_repos(agent, client_factory, settings)


@router.post("/api/v1/agents/{agent_id}/helm/repos")
async def helm_add_repo(
    agent_id: UUID, body: AddRepoBody,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    agent = await _agent_with_address(session, agent_id)
    return await helm_app.add_repo(agent, client_factory, settings, name=body.name, url=body.url)


@router.get("/api/v1/agents/{agent_id}/helm/charts")
async def helm_charts(
    agent_id: UUID, query: str = Query(""),
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Available charts to deploy (helm search repo) — the k8s app catalog."""
    agent = await _agent_with_address(session, agent_id)
    return await helm_app.search_charts(agent, client_factory, settings, query=query)


@router.get("/api/v1/agents/{agent_id}/helm/values")
async def helm_values(
    agent_id: UUID, chart: str = Query(...),
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """A chart's default values (helm show values) — drives the configure form."""
    agent = await _agent_with_address(session, agent_id)
    return await helm_app.chart_values(agent, client_factory, settings, chart=chart)


@router.post("/api/v1/agents/{agent_id}/helm/render")
async def helm_render(
    agent_id: UUID, body: RenderBody,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """helm template — render manifests without a cluster (preview)."""
    agent = await _agent_with_address(session, agent_id)
    return await helm_app.render_release(
        agent, client_factory, settings,
        name=body.name, chart=body.chart, values_yaml=body.values_yaml, values=body.values,
        namespace=body.namespace,
    )


@router.post("/api/v1/agents/{agent_id}/helm/install")
async def helm_install(
    agent_id: UUID, body: InstallBody,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """helm upgrade --install — deploy/upgrade a release on the cluster."""
    agent = await _agent_with_address(session, agent_id)
    return await helm_app.install_release(
        agent, client_factory, settings, name=body.name, chart=body.chart,
        values_yaml=body.values_yaml, values=body.values, namespace=body.namespace,
        create_namespace=body.create_namespace, wait=body.wait,
    )


@router.post("/api/v1/agents/{agent_id}/helm/rollback")
async def helm_rollback(
    agent_id: UUID, body: RollbackBody,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    agent = await _agent_with_address(session, agent_id)
    return await helm_app.rollback_release(
        agent, client_factory, settings, name=body.name, revision=body.revision, namespace=body.namespace)


@router.post("/api/v1/agents/{agent_id}/helm/uninstall")
async def helm_uninstall(
    agent_id: UUID, body: UninstallBody,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    agent = await _agent_with_address(session, agent_id)
    return await helm_app.uninstall_release(agent, client_factory, settings, name=body.name, namespace=body.namespace)
