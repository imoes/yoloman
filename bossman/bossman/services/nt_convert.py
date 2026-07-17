"""Block G11 (runbook persistence): convert between the DB's canonical JSON
and the NestedText (or YAML) authoring form.

Runbooks live in the database as JSON (the parsed Runbook/Role document);
NestedText is the authoring/display format. On save we parse NT/YAML → the
canonical doc; on read we render the doc → NestedText for the editor.
(Modules and checks stay on the filesystem — only runbooks are DB-backed.)
"""

from __future__ import annotations

from typing import Any

import nestedtext
import yaml

from bossman.services.nt_runbook import NTRunbookError, parse_data, parse_document


def nt_to_doc(nt_text: str) -> dict[str, Any]:
    """NestedText authoring text → canonical JSON doc (validated)."""
    return parse_document(nt_text).to_dict()


def yaml_to_doc(yaml_text: str) -> dict[str, Any]:
    """YAML authoring text → canonical JSON doc (validated). Handy for
    importing an existing YAML playbook; it is canonicalized to the runbook
    model (and will render back as NestedText)."""
    try:
        data = yaml.safe_load(yaml_text)
    except yaml.YAMLError as exc:
        raise NTRunbookError(f"not valid YAML: {exc}") from exc
    return parse_data(data, "<yaml>").to_dict()


def _authoring_dict(doc: dict[str, Any]) -> dict[str, Any]:
    """The canonical doc reshaped into the authoring mapping (drop internal
    `kind`, promote role/name, keep only set fields) for NestedText output."""
    out: dict[str, Any] = {}
    if doc.get("kind") == "role":
        out["role"] = doc.get("name", "")
        if doc.get("description"):
            out["description"] = doc["description"]
        if doc.get("parameters"):
            out["parameters"] = doc["parameters"]
        out["steps"] = doc.get("steps", [])
        mon = (doc.get("monitoring") or {}).get("checks") or []
        if mon:
            out["monitoring"] = {"checks": mon}
        routes = (doc.get("notifications") or {}).get("routes") or []
        if routes:
            out["notifications"] = {"routes": routes}
    elif doc.get("chunks") is not None:
        # A chunked plan (the plan-engine format: a plan is a list of named
        # `chunks`, each with its own `steps`, rather than one flat `steps`).
        # Without this branch the YAML/NT views collapsed to an empty
        # `steps: []` — JSON still showed the body because it dumps it whole.
        # Drop internal per-chunk bookkeeping (`source_hash`).
        out["name"] = doc.get("name", "")
        if doc.get("description"):
            out["description"] = doc["description"]
        if doc.get("params"):
            out["params"] = doc["params"]
        if doc.get("targets"):
            out["targets"] = doc["targets"]
        out["chunks"] = [{k: v for k, v in c.items() if k != "source_hash"} for c in doc["chunks"]]
        if doc.get("final_handler"):
            out["final_handler"] = doc["final_handler"]
    else:
        out["name"] = doc.get("name", "")
        if doc.get("targets"):
            out["targets"] = doc["targets"]
        # Typed input-mask schema — must survive the doc→NT round-trip, else a
        # loaded runbook silently loses its parameters on the next save.
        if doc.get("parameters"):
            out["parameters"] = doc["parameters"]
        out["steps"] = doc.get("steps", [])
    return out


def doc_to_nt(doc: dict[str, Any]) -> str:
    """Canonical JSON doc → NestedText authoring text (for the editor).
    NestedText leaves must be strings; default=str coerces bools/numbers."""
    return nestedtext.dumps(_authoring_dict(doc), default=str)


def doc_to_yaml(doc: dict[str, Any]) -> str:
    """Canonical JSON doc → YAML authoring text (for the editor's YAML view).
    Uses the same authoring reshape as NestedText, so all three formats
    (NT/YAML/JSON) round-trip through the same canonical body."""
    return yaml.safe_dump(_authoring_dict(doc), sort_keys=False, default_flow_style=False, allow_unicode=True)
