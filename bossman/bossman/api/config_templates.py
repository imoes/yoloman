"""Block K2 — the Class-B config template catalog. Serves the templates in
configs/config_templates/ (each a <name>/ dir with template.j2 + schema.json +
sample.json) so the Configuration tab can bind a discovered config file to its
template and drive a schema-generated form. The template text is returned too,
so the UI can send it inline to the agent's template_render (the agent never
needs the template files locally)."""

from __future__ import annotations

import json
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException

from bossman.api.auth import get_current_identity
from bossman.config import Settings, get_settings

router = APIRouter()


def _load_template(d: Path) -> dict | None:
    tpl = d / "template.j2"
    if not tpl.is_file():
        return None
    out: dict = {"name": d.name, "template": tpl.read_text()}
    for key, fname in (("schema", "schema.json"), ("sample", "sample.json")):
        f = d / fname
        if f.is_file():
            try:
                out[key] = json.loads(f.read_text())
            except ValueError:
                out[key] = {}
        else:
            out[key] = {}
    return out


def load_template_bodies(settings) -> dict[str, str]:
    """{name: raw Jinja2 body} for every config template — so a runbook's
    `config_template` step can reference one by name and hand its body to the
    agent's template_render apply (the agent does the actual rendering)."""
    root = Path(settings.config_templates_dir)
    out: dict[str, str] = {}
    if root.is_dir():
        for d in sorted(root.iterdir()):
            if d.is_dir():
                t = _load_template(d)
                if t is not None:
                    out[t["name"]] = t["template"]
    return out


@router.get("/api/v1/config-templates")
async def list_config_templates(
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
) -> dict:
    """Every Class-B template: [{name, template, schema, sample}]. `schema`
    drives the edit form; `template` is sent inline to the agent on apply."""
    root = Path(settings.config_templates_dir)
    templates = []
    if root.is_dir():
        for d in sorted(root.iterdir()):
            if d.is_dir():
                t = _load_template(d)
                if t is not None:
                    templates.append(t)
    return {"templates": templates}


@router.get("/api/v1/config-templates/{name}")
async def get_config_template(
    name: str,
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
) -> dict:
    # Guard against path traversal — a template name is a single dir label.
    if "/" in name or name in ("", ".", ".."):
        raise HTTPException(status_code=422, detail="invalid template name")
    t = _load_template(Path(settings.config_templates_dir) / name)
    if t is None:
        raise HTTPException(status_code=404, detail=f"no such config template {name}")
    return t
