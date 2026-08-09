"""Help / docs REST surface (Block G10): the README as the in-app Help page,
plus a section search. Read-only, any authenticated caller."""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Depends

from bossman.api.auth import get_current_identity
from bossman.config import Settings, get_settings
from bossman.services import help as help_svc

router = APIRouter()


@router.get("/api/v1/help")
async def get_help(
    settings: Settings = Depends(get_settings), _identity=Depends(get_current_identity)
) -> dict[str, Any]:
    """The README markdown, rendered by the UI's Help page."""
    return {"markdown": help_svc.read_readme(settings.help_root)}


@router.get("/api/v1/help/search")
async def search_help(
    q: str, limit: int = 5, settings: Settings = Depends(get_settings), _identity=Depends(get_current_identity)
) -> dict[str, Any]:
    """Doc sections matching a query — backs the AI's search_help tool and a
    Help-page search box."""
    return {"query": q, "results": help_svc.search_help(settings.help_root, q, limit)}
