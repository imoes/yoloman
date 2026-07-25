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


def _summarize_document(doc: dict[str, Any], budget: int = 18000) -> str:
    """Bound the document to a model-sized context: keep config + desired + a
    generations summary + the TOP topology edges (not all — there can be tens of
    thousands), then hard-cap the serialized size."""
    out: dict[str, Any] = {"agent": doc.get("agent"), "errors": doc.get("errors") or {}}

    cfg = (doc.get("config") or {}).get("observed")
    if isinstance(cfg, dict):
        files = cfg.get("config") if isinstance(cfg.get("config"), dict) else {}
        out["config"] = {
            "files": {p: v for p, v in list(files.items())[:60]},   # bounded set of parsed configs
            "file_count": len(files),
            "services": (cfg.get("services") or [])[:80],
        }
    if "desired" in doc:
        out["desired"] = doc["desired"].get("state") if isinstance(doc.get("desired"), dict) else doc["desired"]

    gens = doc.get("generations")
    if isinstance(gens, dict):
        gl = gens.get("generations") if isinstance(gens.get("generations"), list) else None
        out["generations"] = {"count": len(gl) if gl is not None else None, "latest": (gl or [])[:5]}

    topo = (doc.get("topology") or {}).get("edges")
    if isinstance(topo, list):
        top = sorted(topo, key=lambda e: e.get("event_count") or 0, reverse=True)[:40]
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
