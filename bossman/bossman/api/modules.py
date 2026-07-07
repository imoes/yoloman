"""GET /api/v1/modules — the module-management surface (Block H4): the
Starlark module library (docs/plan.md Blocks G7/G8) exposed to the UI.
Read-only by design: the library is *written* exclusively through the
validated submit_module MCP tool (the translation pipeline) — the UI
browses, it never bypasses the validation gate.
"""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Depends, HTTPException

from bossman.api.auth import get_current_identity
from bossman.config import Settings, get_settings
from bossman.services import module_library

router = APIRouter()


@router.get("/api/v1/modules")
async def list_modules_route(
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """The whole catalog in one call: per-collection progress + one row
    per module (translated rows carry description/writes)."""
    st = module_library.status(settings.modules_dir, settings.module_sources_dir)
    modules = module_library.list_modules(settings.modules_dir, settings.module_sources_dir)
    # The list view doesn't need the (long) missing-fqcn arrays repeated
    # per collection — the module rows already carry translated flags.
    collections = {
        name: {"total": entry["total"], "translated": entry["translated"]} for name, entry in st["collections"].items()
    }
    return {"total": st["total"], "translated": st["translated"], "collections": collections, "modules": modules}


@router.get("/api/v1/modules/{fqcn}")
async def get_module_route(
    fqcn: str,
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """One module's detail: the stored metadata + Starlark source for a
    translated module, or the dumped argspec/description for one still in
    the queue (so the UI can show every module, not just finished ones)."""
    try:
        detail = module_library.load_module(settings.modules_dir, fqcn)
        detail["translated"] = True
        return detail
    except module_library.ModuleLibraryError:
        pass
    try:
        source = module_library.load_source(settings.module_sources_dir, fqcn)
    except module_library.ModuleLibraryError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    return {
        "fqcn": fqcn,
        "translated": False,
        "metadata": {
            "name": source.get("name", ""),
            "collection": source.get("collection", ""),
            "short_description": source.get("short_description", ""),
            "options": (source.get("doc") or {}).get("options") or {},
        },
        "star_code": "",
    }
