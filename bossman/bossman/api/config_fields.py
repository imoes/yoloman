"""Unified per-path field spec — the `describe()` of a config file as ONE
endpoint, so the UI stops juggling two catalogs (raw config-directives vs
config-templates) and two field-spec shapes.

For a given config path it answers a single question — "what typed fields does
this file have, and how is it written?" — resolving the two irreducible write
paths (see docs/config-model-consolidation.md):

  codec != none  ->  write:"codec"     fields from codec ⊕ directive catalog
  codec == none  ->  write:"template"  fields from the template's schema.json (+ .j2)

Read-only: it composes the offline-generated catalogs (config_codecs.json,
config_directives.json, config_templates/). Host-independent — the authoring
view (OU/group policy). Per-host observed merging stays in ConfigResource.schema.
"""
from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Depends

from bossman.api.auth import get_current_identity
from bossman.api.config_templates import _load_template
from bossman.config import Settings, get_settings
from bossman.services import config_schema

router = APIRouter()


def _load_json(path_str: str) -> dict:
    try:
        data = json.loads(Path(path_str).read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _field_from_directive(spec: dict) -> dict:
    """Directive spec {type, values?, default?, min?, max?, description?} ->
    unified FieldDef {type, enum?, default?, description?, min?, max?}."""
    values = spec.get("values") or spec.get("enum")
    out: dict[str, Any] = {"type": "enum" if isinstance(values, list) and values else spec.get("type", "string")}
    if isinstance(values, list) and values:
        out["enum"] = [str(v) for v in values]
    if spec.get("default") not in (None, ""):
        out["default"] = spec["default"]
    if isinstance(spec.get("description"), str) and spec["description"]:
        out["description"] = spec["description"]
    for k in ("min", "max"):
        if isinstance(spec.get(k), int):
            out[k] = spec[k]
    return out


def _template_for_path(path: str, codecs: dict, tdir: Path) -> str | None:
    """Resolve a freeform file to its whole-file template dir. Basename (minus
    .conf/.cfg) then a codec `packages` name — confident matches only."""
    base = path.rsplit("/", 1)[-1]
    for cand in (base, re.sub(r"\.(conf|cfg)$", "", base)):
        if cand and (tdir / cand / "schema.json").is_file():
            return cand
    for pkg in (codecs.get(path) or {}).get("packages") or []:
        if (tdir / pkg / "schema.json").is_file():
            return pkg
    return None


@router.get("/api/v1/config-fields")
async def config_fields(
    path: str,
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """One field spec for `path`: {path, write, format?, separator?, template?,
    fields:{key:FieldDef}, available}."""
    codecs = _load_json(settings.config_codecs_path)
    codec = codecs.get(path) or {}
    codec_kind = codec.get("codec")

    if codec_kind and codec_kind != "none":
        directives = config_schema.load_catalog(settings)
        dirs = config_schema.catalog_for_path(path, directives)
        fields = {k: _field_from_directive(v) for k, v in dirs.items() if isinstance(v, dict)}
        return {
            "path": path, "write": "codec",
            "format": codec_kind, "separator": codec.get("separator", ""),
            "fields": fields, "available": True,
        }

    # Freeform (codec == none, or unknown): the whole-file template is the spec.
    tdir = Path(settings.config_templates_dir)
    tpl = _template_for_path(path, codecs, tdir)
    if tpl:
        t = _load_template(tdir / tpl) or {}
        return {
            "path": path, "write": "template",
            "template": t.get("template", ""),
            "fields": t.get("schema") or {}, "available": True,
        }
    # NO WAY TO EDIT BY FIELD — and the two reasons are different, so they get different names instead of
    # both being called a codec write with zero fields.
    #
    # `"codec" if codec_kind else "unknown"` used to answer write="codec", format="none", fields={} for a file
    # whose record says "no grammar fits": the string "none" is truthy. So the record said one thing and the
    # API said the opposite about the same file — and with the RedHat corpus measured, thousands of files now
    # carry exactly that record, /etc/httpd/conf/httpd.conf among them.
    #
    #   freeform  MEASURED: no codec fits this file, and no template exists for it yet. It is editable as raw
    #             text, and generating a template is the work that would make it editable by field.
    #   unknown   nothing has ever been recorded about this path. Not the same claim at all.
    return {
        "path": path,
        "write": "freeform" if codec_kind == "none" else "unknown",
        "reason": ("no codec fits this file (measured) and no template renders it yet — raw text only"
                   if codec_kind == "none" else
                   "this path has no codec record and no template — nothing is known about it yet"),
        "format": None, "separator": "",
        "fields": {}, "available": False,
    }
