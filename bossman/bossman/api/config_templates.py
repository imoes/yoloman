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

from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.config import Settings, get_settings
from bossman.db.models import Agent
from bossman.db.session import get_session
from bossman.services.capabilities import family_of
from bossman.services.template_index import build_template_index

router = APIRouter()


def _load_template(d: Path) -> dict | None:
    tpl = d / "template.j2"
    if not tpl.is_file():
        return None
    out: dict = {"name": d.name, "template": tpl.read_text()}
    for key, fname in (("schema", "schema.json"), ("sample", "sample.json"), ("capabilities", "capabilities.json")):
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


@router.get("/api/v1/config-templates/index")
async def config_template_index(
    family: str = "",
    agent_id: UUID | None = None,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
) -> dict:
    """{paths: {"/etc/nginx/nginx.conf": {template, source, role?}}, conflicts: [...]}.

    The explicit answer to "which template renders THIS file", replacing a basename guess that resolved
    /etc/aardvark-dns/aardvark-dns.conf to the template rendering forward.conf — and, since the write
    path is template_render (whole file, no merge), would have written one file's content over another.

    DECLARED BEFORE /{name} on purpose. FastAPI matches routes in declaration order, so the path
    parameter below would otherwise swallow "index" and serve a 404 for a template literally named
    index. Route order is load-bearing here, not style.

    Also replaces a 33.7 MB download: the host page used to fetch every template BODY across 5460
    directories to do a string comparison. This is path→name pairs.
    """
    # `agent_id` means "for this host": the family is derived HERE with family_of(facts), the same function
    # the wizard and the capability matcher use, so the os_release sniffing exists once. Without it the index
    # is the host-independent authoring view, which is the right answer for OU policy.
    if agent_id is not None and not family:
        agent = await session.get(Agent, agent_id)
        if agent is not None:
            family = family_of(agent.facts or {})
    return build_template_index(
        Path(settings.config_templates_dir).parent / "package_catalog.json",
        settings.config_codecs_path,
        settings.config_templates_dir,
        family,
        # Passed EXPLICITLY, like every other input: the builder's fallback derives the verdicts from the
        # catalog's directory, and in the container the catalog sits at /app while the verdicts live under
        # /app/configs. A silently-not-found verdict file withdraws nothing and looks exactly like a clean
        # index — the one failure mode this measurement exists to prevent.
        settings.config_path_verdicts_path,
    )


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
