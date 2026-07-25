"""The App catalog (app-system increment 1) — a thin READ-MODEL over
`package_catalog.json` + `config_templates/`, presenting each installable thing
as a unified **App** with one lifecycle across target tiers (native | docker |
k8s). See docs/app-model.md.

Increment 1 is native-only and read-only: it reshapes the existing catalog into
the App shape (adds `targets.native`) and serves each App's values_schema so the
app-store UI can render the configure form. Docker/k8s targets + the deploy
verbs land in later increments; the App API is the seam they plug into.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Depends, HTTPException

from bossman.api.auth import get_current_identity
from bossman.config import Settings, get_settings

router = APIRouter()


def _catalog_path(settings: Settings) -> Path:
    return Path(settings.config_templates_dir).parent / "package_catalog.json"


def _load_catalog(settings: Settings) -> dict[str, Any]:
    path = _catalog_path(settings)
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _app_summary(app_id: str, entry: dict[str, Any]) -> dict[str, Any]:
    """Reshape a package_catalog entry into an App summary. The native target is
    the entry itself (role + template + per-family package/service/config)."""
    template = entry.get("template")
    return {
        "id": app_id,
        "label": entry.get("label", app_id),
        "category": entry.get("category", "other"),
        "icon": entry.get("icon", "widgets"),
        "description": entry.get("description", ""),
        "configurable": bool(template),
        "targets": {
            "native": {
                "role": app_id,
                "template": template,
                "validate_cmd": entry.get("validate_cmd"),
                "families": entry.get("families", {}),
            },
            # docker / k8s tiers are declared by later increments; absent = not
            # yet supported for this app (the UI shows only what's present).
        },
    }


@router.get("/api/v1/apps")
async def list_apps(
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """The unified app catalog: [{id, label, category, icon, description,
    configurable, targets:{native:{…}}}]. A thin view over package-catalog."""
    catalog = _load_catalog(settings)
    apps = [_app_summary(k, v) for k, v in sorted(catalog.items()) if isinstance(v, dict)]
    return {"apps": apps, "count": len(apps)}


@router.get("/api/v1/apps/{app_id}")
async def get_app(
    app_id: str,
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """One App with its values_schema + sample (for the configure form), read
    from the app's Class-B template dir when present."""
    entry = _load_catalog(settings).get(app_id)
    if not isinstance(entry, dict):
        raise HTTPException(status_code=404, detail=f"no such app: {app_id}")
    app = _app_summary(app_id, entry)
    template = entry.get("template")
    if template:
        tdir = Path(settings.config_templates_dir) / template
        # path-traversal guard: the resolved dir must stay under the templates root.
        root = Path(settings.config_templates_dir).resolve()
        if tdir.resolve().parent == root and (tdir / "schema.json").is_file():
            try:
                app["values_schema"] = json.loads((tdir / "schema.json").read_text())
                sample = tdir / "sample.json"
                app["sample"] = json.loads(sample.read_text()) if sample.is_file() else {}
            except (OSError, ValueError):
                app["values_schema"] = {}
                app["sample"] = {}
    return app
