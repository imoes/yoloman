"""The real LLM translator: foreign source text (e.g. one Ansible task
file) -> a normalized Bossman plan chunk (see docs/plan.md's "real LLM
translator"). Checks the existing chunk-similarity cache first — "the LLM
only decides which chunks can be reused" becomes concrete here: a close
enough match short-circuits the whole LLM call. Grammar-constrained JSON
output (response_format: json_schema) plus plan_loader.parse_plan as the
sole validation gate means no bespoke validator was written for this —
parse_plan's existing PlanError messages are the retry-feedback signal.

Framework-free (no FastAPI import), like services/plan_engine.py and
services/chunk_similarity.py, so it's reachable from the REST API and
tests without duplicating logic.

Deliberately scoped to module-call steps only for this first increment
(documented limit, same discipline as the img_docker translation's own
scope cuts): pipeline/upload steps and final_handler still need to be
added by hand afterward, exactly like img_docker.yaml's own
"systemctl daemon-reload" pipeline step and "Restart Docker" handler
were. No MCP tool exposes this — translation is an authoring-time action
for a human/CI to review before a plan file is committed, not a runtime
fleet-management action (see docs/plan.md's earlier, explicit scope cut:
"kein KI-Übersetzer via MCP heute").
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from sqlalchemy.ext.asyncio import AsyncSession

from bossman.services.chat_client import ChatClient, ChatClientError
from bossman.services.chunk_similarity import find_similar_chunks, index_chunk
from bossman.services.embedding_client import EmbeddingClient
from bossman.services.plan_loader import Chunk, PlanError, hash_source_text, parse_plan

# The exact module names implemented in internal/modules/*.go (each
# module's own Name() method) — kept in sync by hand, the same accepted
# manual-sync point as db.models.CHUNK_EMBEDDING_DIM. Enumerating these as
# a JSON-schema `enum` (grammar-level, not just prompt text) makes it
# structurally impossible for the LLM to hallucinate a module this agent
# doesn't actually have, closing a whole class of failure at the decoding
# level rather than relying on validation to catch it after the fact.
KNOWN_MODULES = [
    "apt", "apt_key", "apt_repository", "assemble", "blockinfile", "command", "copy", "cron",
    "deb822_repository", "debconf", "dnf", "dnf5", "dpkg_selections", "expect", "fetch", "file",
    "find", "getent", "get_url", "git", "group", "hostname", "iptables", "known_hosts", "lineinfile",
    "package", "package_facts", "ping", "pip", "raw", "reboot", "replace", "rpm_key", "script",
    "service", "service_facts", "setup", "shell", "slurp", "stat", "subversion", "systemd",
    "systemd_service", "sysvinit", "tempfile", "template", "timezone", "unarchive", "uri", "user",
    "wait_for", "yum", "yum_repository",
]

_STEP_JSON_SCHEMA = {
    "type": "object",
    "properties": {
        "name": {"type": "string"},
        "module": {"type": "string", "enum": KNOWN_MODULES},
        "params": {"type": "object"},
        "when": {"type": ["string", "null"]},
        "register": {"type": ["string", "null"]},
        "check_mode": {"type": "boolean"},
    },
    "required": ["name", "module", "params"],
}

_CHUNK_JSON_SCHEMA = {
    "type": "object",
    "properties": {
        "os_family": {"type": ["array", "null"], "items": {"type": "string"}},
        "steps": {"type": "array", "minItems": 1, "items": _STEP_JSON_SCHEMA},
    },
    "required": ["steps"],
}

_SYSTEM_PROMPT = (
    "You translate one source automation-role file (e.g. an Ansible task file) into a single "
    "Bossman plan chunk: a list of module-call steps. Each step calls exactly one of Bossman's "
    "own built-in modules (the same names and parameters as the equivalent Ansible built-in "
    "module — Bossman's modules mirror Ansible's parameter names directly, but only Ansible's "
    "primary parameter name, never a legacy alias: the apt module's package list is always "
    "\"name\", never \"pkg\"; a symlink's own path is always \"path\", never \"dest\"). Only emit "
    "steps for actions expressible as a single module call with a params object; do not invent "
    "parameters a module doesn't have. If the source declares an OS-specific dispatch (e.g. "
    "\"{{ ansible_distribution }}\"-based file inclusion), leave os_family null — that dispatch "
    "decision is made by the caller, not by you."
)


class TranslationError(Exception):
    """Raised when translation fails after exhausting all retries — always
    carries the last validation error the LLM's output failed."""


@dataclass
class TranslationResult:
    chunk: Chunk
    source: Literal["reused", "llm"]
    similar_chunk_id: str | None
    attempts: int


def _reshape_step(step: dict) -> dict:
    """Converts one LLM-produced step ({name, module, params, when?,
    register?, check_mode?}) into the real plan-step dict parse_plan
    expects (a bare `<module>: params` key) — done in Python
    rather than asked of the LLM directly, since a literal step key is
    more error-prone for a model to produce reliably than a plain "module"
    string field constrained by a schema enum."""
    out = {"name": step["name"], step["module"]: step["params"]}
    if step.get("when") is not None:
        out["when"] = step["when"]
    if step.get("register") is not None:
        out["register"] = step["register"]
    if step.get("check_mode"):
        out["check_mode"] = True
    return out


def _wrap_as_plan_doc(chunk_name: str, os_family: list[str] | None, steps: list[dict]) -> bytes:
    doc = {
        "name": "_translation_preview",
        "chunks": [{"name": chunk_name, "steps": [_reshape_step(s) for s in steps]}],
    }
    if os_family is not None:
        doc["chunks"][0]["os_family"] = os_family
    return json.dumps(doc).encode()


def _reconstruct_chunk(chunk_name: str, translated_json: str) -> Chunk:
    """Rebuilds a real Chunk from a previously stored translated_json (see
    db.models.ChunkEmbedding.translated_json) by reusing parse_plan — no
    separate deserializer, no LLM call, no network."""
    stored = json.loads(translated_json)
    doc = json.dumps({"name": "_reused", "chunks": [{"name": chunk_name, **stored}]}).encode()
    plan = parse_plan(doc, Path("<reused>"))
    return plan.chunks[0]


async def translate_chunk(
    session: AsyncSession,
    embedding_client: EmbeddingClient,
    chat_client: ChatClient,
    *,
    plan_name: str,
    chunk_name: str,
    source_text: str,
    similarity_threshold: float,
    max_retries: int = 2,
) -> TranslationResult:
    """Translates source_text into one Bossman chunk. Checks the chunk-
    similarity cache first (see services/chunk_similarity.py) — a hit with
    stored translated_json short-circuits the LLM call entirely. On a miss,
    calls chat_client with a JSON-schema-constrained request, validates the
    reshaped result via plan_loader.parse_plan (retrying, with the
    validation error fed back to the model, up to max_retries times), and
    on success persists it via index_chunk so future lookups can reuse it.

    Raises TranslationError only after every retry is exhausted — a
    persisted, reusable result or a clear error, never a silent partial
    translation.
    """
    similar = await find_similar_chunks(
        session, embedding_client, source_text=source_text, top_k=1, threshold=similarity_threshold
    )
    if similar and similar[0].translated_json is not None:
        match = similar[0]
        chunk = _reconstruct_chunk(chunk_name, match.translated_json)
        return TranslationResult(chunk=chunk, source="reused", similar_chunk_id=match.chunk_id, attempts=0)

    messages = [
        {"role": "system", "content": _SYSTEM_PROMPT},
        {"role": "user", "content": source_text},
    ]

    last_error: str | None = None
    for attempt in range(1, max_retries + 2):  # 1 initial attempt + max_retries retries
        try:
            llm_output = await chat_client.complete_json(messages, _CHUNK_JSON_SCHEMA, "bossman_chunk")
        except ChatClientError as exc:
            raise TranslationError(str(exc)) from exc

        try:
            doc_bytes = _wrap_as_plan_doc(chunk_name, llm_output.get("os_family"), llm_output["steps"])
            plan = parse_plan(doc_bytes, Path("<translated>"))
        except (PlanError, KeyError, TypeError) as exc:
            last_error = str(exc)
            messages.append({"role": "assistant", "content": json.dumps(llm_output)})
            messages.append(
                {
                    "role": "user",
                    "content": f"Your previous response was invalid: {last_error}. Return a corrected "
                    "JSON object matching the same schema.",
                }
            )
            continue

        chunk = plan.chunks[0]
        await index_chunk(
            session,
            embedding_client,
            plan_name=plan_name,
            chunk_name=chunk_name,
            chunk_id=chunk.chunk_id,
            source_hash=hash_source_text(source_text),
            source_text=source_text,
            translated_json=json.dumps({"os_family": chunk.os_family, "steps": _raw_steps(llm_output["steps"])}),
        )
        return TranslationResult(chunk=chunk, source="llm", similar_chunk_id=None, attempts=attempt)

    raise TranslationError(f"translation failed after {max_retries + 1} attempts: {last_error}")


def _raw_steps(llm_steps: list[dict]) -> list[dict]:
    """The reshaped (`<module>: params`) form of every step,
    for storage in translated_json — the same shape _wrap_as_plan_doc
    already builds, factored out so it's computed once from the LLM's
    already-validated output rather than re-derived from the parsed Chunk
    (which has lost the distinction between an explicit `check_mode: false`
    and an absent key — round-tripping through Chunk.canonical_dict would
    still work, but this is simpler and keeps translated_json exactly what
    was stored at parse time)."""
    return [_reshape_step(s) for s in llm_steps]
