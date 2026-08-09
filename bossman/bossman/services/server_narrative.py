"""Self-explaining infrastructure (killer-feature increment a) — turn the live
server-document (increment d) into always-current documentation and natural-
language answers, grounded strictly in live state (never invented).

`explain_server` composes the document, SUMMARIZES it to a bounded context (the
raw document — esp. topology — is far larger than a model context), and asks the
LLM to either document the server or answer a specific question. Because the
document is the live desired+observed state, the output cannot go stale the way
a hand-written wiki does.
"""
from __future__ import annotations

import json
from typing import Any

from bossman.services.server_document import build_server_document

_SYS_DOC = (
    "You explain and document a Linux server STRICTLY from its live state document "
    "(the source of truth — never invent facts, never guess). Produce concise, accurate "
    "operator documentation: what the server runs, its notable configuration and the reason "
    "where evident, its dependencies (from topology), and recent changes (from generations). "
    "Reference concrete config file paths. Prefer bullet points; be specific, not generic."
)
_SYS_QA = (
    "You answer a question about a Linux server STRICTLY from its live state document below "
    "(the source of truth). Never invent. If the document does not contain the answer, say so "
    "explicitly. Cite the config path / section your answer comes from. Be concise and specific."
)


def _summarize_document(doc: dict[str, Any], budget: int = 22000, config_budget: int = 16000,
                        per_file_raw: int = 800) -> str:
    """Bound the document to a model-sized context, PRIORITIZING actual config
    content (the whole point — the AI must see real config, not just names):
    each observed file's parsed `values` (codec'd) or truncated `raw` text
    (codec-less, e.g. Caddyfile/nginx sites — where TLS etc. lives). Topology is
    reduced to a tiny top-N (there can be tens of thousands of edges). Config is
    emitted first so truncation eats topology, not config."""
    out: dict[str, Any] = {"agent": doc.get("agent"), "errors": doc.get("errors") or {}}

    cfg = (doc.get("config") or {}).get("observed")
    if isinstance(cfg, dict):
        items = cfg.get("config") if isinstance(cfg.get("config"), list) else []
        files: list[dict[str, Any]] = []
        used = 0
        for it in items:
            if not isinstance(it, dict):
                continue
            entry: dict[str, Any] = {"path": it.get("path"), "format": it.get("format") or None}
            vals = it.get("values")
            if isinstance(vals, dict) and vals:
                entry["values"] = vals
            else:
                raw = it.get("raw")
                if isinstance(raw, str) and raw.strip():
                    entry["raw"] = raw[:per_file_raw] + ("… [truncated]" if len(raw) > per_file_raw else "")
            size = len(json.dumps(entry, default=str))
            if used + size > config_budget:               # keep the path, drop the body once over budget
                files.append({"path": it.get("path"), "note": "omitted (context budget)"})
                continue
            used += size
            files.append(entry)
        out["config"] = {"file_count": len(items), "files": files, "services": (cfg.get("services") or [])[:60]}

    if "desired" in doc:
        out["desired"] = doc["desired"].get("state") if isinstance(doc.get("desired"), dict) else doc["desired"]

    gens = doc.get("generations")
    if isinstance(gens, dict):
        gl = gens.get("generations") if isinstance(gens.get("generations"), list) else None
        out["generations"] = {"count": len(gl) if gl is not None else None, "latest": (gl or [])[:5]}

    topo = (doc.get("topology") or {}).get("edges")
    if isinstance(topo, list):
        top = sorted(topo, key=lambda e: e.get("event_count") or 0, reverse=True)[:15]
        out["topology"] = {"edge_count": len(topo), "top_edges": top}

    text = json.dumps(out, indent=1, default=str)
    return text if len(text) <= budget else text[:budget] + "\n… [truncated]"


async def explain_server(
    session,
    agent,
    client_factory,
    settings,
    chat,
    question: str | None = None,
) -> dict[str, Any]:
    """Documentation (question=None) or a grounded NL answer, from live state."""
    doc = await build_server_document(
        session, agent, client_factory, settings,
        include={"config", "desired", "generations", "topology"},
    )
    summary = _summarize_document(doc)
    system = _SYS_QA if question else _SYS_DOC
    user = f"SERVER: {agent.name}\n\nLIVE STATE DOCUMENT:\n{summary}"
    if question:
        user += f"\n\nQUESTION: {question}"
    answer = await chat.complete_text([
        {"role": "system", "content": system},
        {"role": "user", "content": user},
    ])
    return {
        "agent": {"id": str(agent.id), "name": agent.name},
        "question": question,
        "answer": answer,
        "grounding": {"context_chars": len(summary), "sections": doc.get("included"), "errors": doc.get("errors")},
    }
