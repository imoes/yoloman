"""Block K2 — the Class-B config template catalog. Serves the templates in
configs/config_templates/ (each a <name>/ dir with template.j2 + schema.json +
sample.json) so the Configuration tab can bind a discovered config file to its
template and drive a schema-generated form. The template text is returned too,
so the UI can send it inline to the agent's template_render (the agent never
needs the template files locally)."""

from __future__ import annotations

import json
import re
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
                    meta = d / "meta.json"
                    if meta.is_file():
                        try:
                            m = json.loads(meta.read_text())
                        except (OSError, ValueError):
                            m = {}
                        # A template made for ONE family's file is also reachable as "@<family>:<path>" — the
                        # key a `config_template` step asks for first on a host of that family. Without it the
                        # wizard rendered the role's single (Debian) template on every family: measured in the
                        # package e2e, a RedHat host would have received Debian's nginx.conf.
                        if isinstance(m, dict) and m.get("target_path"):
                            # What this template RENDERS, so a step can refuse to write it over a different file.
                            out[target_key(t["name"])] = m["target_path"]
                        if isinstance(m, dict) and m.get("family") and m.get("target_path"):
                            out[family_key(m["family"], m["target_path"])] = with_own_defaults(
                                t["template"], t.get("schema") or {})
    return out


_IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def with_own_defaults(body: str, schema: dict) -> str:
    """The body, preceded by `{%- set f = f | default(<schema default>, true) -%}` for each field.

    A family template is rendered with the variables of the ROLE's form — and that form was built from the role's
    own (Debian) template, whose field names differ. Measured in the package e2e: on a RedHat host the wizard
    rendered nginx-redhat with `user` unset and wrote `user ;`, which nginx refuses. With its defaults inline the
    family template renders its own shipped values for every field the form does not name, and an empty value
    counts as unset (`default(..., true)`). A field the form DOES supply still wins."""
    lines = []
    for name, spec in (schema or {}).items():
        if not isinstance(spec, dict) or not _IDENT.match(str(name)):
            continue
        default = spec.get("default")
        if default is None:
            continue
        literal = json.dumps(default)
        if literal.endswith('\\"'):
            # The agent's gonja cannot lex a string literal that ends in an escaped backslash ("…\\") — the whole
            # template failed to parse (exim4-redhat: log_selector "… +smtp_syntax_error \\", a line continuation).
            # Left to the template's own inline default instead.
            continue
        lines.append("{%- set " + name + " = " + name + " | default(" + literal + ", true) -%}")
    return ("\n".join(lines) + "\n" + body) if lines else body


def target_key(name: str) -> str:
    """The templates-map key holding the file template `name` records it renders (its meta.json target_path)."""
    return f"@target:{name}"


def family_key(family: str, path: str) -> str:
    """The templates-map key of the template that renders `path` for hosts of `family`."""
    return f"@{family}:{path}"


@router.get("/api/v1/config-templates")
async def list_config_templates(
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
) -> dict:
    """Every Class-B template as [{name, target_path, source}] — NO BODIES.

    It used to return each template's body, schema and sample: measured against this catalog, a 36 MB JSON
    document assembled in memory on every call. The host page was moved off it once already (see the note on
    /config-templates/index, "replaces a 33.7 MB download"), but seven package snapins still called it — each
    to pull the whole catalog and then `.find()` ONE hard-coded name. They now ask for that name directly.

    A listing is a listing: what a caller choosing a template needs is the name, the file it renders and why
    the claim exists. The body comes from GET /config-templates/{name}, for the one that was chosen.

    NO withheld COUNT HERE, deliberately. Bossman serves the whole tree, so there is nothing withheld to
    report; the agent's reply carries that number because the PACKAGE ships only the reachable subset. Adding
    a permanent "withheld: 0" to this reply would be a second place claiming to answer a question only the
    agent has.
    """
    root = Path(settings.config_templates_dir)
    templates = []
    if root.is_dir():
        for d in sorted(root.iterdir()):
            # is_file() rather than loading it: the listing must not read 7 MB off disk to count.
            if not d.is_dir() or not (d / "template.j2").is_file():
                continue
            entry: dict = {"name": d.name}
            meta = d / "meta.json"
            if meta.is_file():
                try:
                    m = json.loads(meta.read_text())
                except ValueError:
                    m = {}
                if isinstance(m, dict):
                    entry["target_path"] = m.get("target_path")
                    entry["source"] = m.get("source")
            templates.append(entry)
    return {"templates": templates,
            "detail": "GET /api/v1/config-templates/{name} for a template's body and schema"}


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
    """One template's body, schema and sample values, by name.

    Separate from the listing on purpose: the listing used to return **every** body — about 36 MB —
    while each of its seven callers wanted one. The list now carries names and target paths, and this
    returns the ~8 KB a caller actually opens.
    """
    if "/" in name or name in ("", ".", ".."):
        raise HTTPException(status_code=422, detail="invalid template name")
    t = _load_template(Path(settings.config_templates_dir) / name)
    if t is None:
        raise HTTPException(status_code=404, detail=f"no such config template {name}")
    return t
