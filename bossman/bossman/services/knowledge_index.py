"""Infra knowledge indexer — turn the LIVE fleet into embedded knowledge cards.

Each card is a compact natural-language description of one facet of the running
infrastructure (a host's identity + health, its current problems, its network
edges), so that a single semantic query can surface the relevant facts from ANY
host — the substrate for infra-grounded RAG (services/knowledge_search.py +
api/knowledge.py). Re-indexing is incremental: a card's text is content-hashed and
only changed/new cards are re-embedded, so it is cheap to run on the poller's
cadence. Cards whose source entity disappeared are pruned.

This is deliberately structured (not a dump of every metric) — the goal is that
the AI can reason about relationships and offer solutions, which needs concise,
labelled facts, not raw rows.
"""
from __future__ import annotations

import hashlib
import logging
from dataclasses import dataclass
from datetime import datetime, timezone

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from bossman.config import Settings
from bossman.db.models import Agent, AgentObservedState, HostEdge, KnowledgeEmbedding, Service
from bossman.services.embedding_client import EmbeddingClient, EmbeddingClientError, embedding_client_for

logger = logging.getLogger(__name__)

_EMBED_BATCH = 32
_MAX_CARD_CHARS = 2000

# Throttle state for maybe_reindex (called every poll cycle).
_last_reindex: datetime | None = None


@dataclass
class Card:
    doc_id: str
    kind: str
    ref_id: str | None
    host_id: str | None
    title: str
    text: str


def _hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _clip(text: str) -> str:
    return text if len(text) <= _MAX_CARD_CHARS else text[:_MAX_CARD_CHARS] + " …"


def _facts_summary(facts: dict) -> str:
    os_ = facts.get("os") or {}
    bits = []
    name = os_.get("pretty_name") or os_.get("distribution") or os_.get("name")
    if name:
        bits.append(f"OS {name}")
    if os_.get("kernel"):
        bits.append(f"kernel {os_['kernel']}")
    cpu = facts.get("cpu") or {}
    if cpu.get("count") or cpu.get("cores"):
        bits.append(f"{cpu.get('count') or cpu.get('cores')} CPU")
    mem = facts.get("memory") or {}
    total = mem.get("total_mb") or mem.get("total")
    if total:
        bits.append(f"{total} MB RAM")
    return ", ".join(bits)


def _config_paths(obs_row: AgentObservedState | None) -> list[str]:
    if obs_row is None or not obs_row.observed:
        return []
    data = obs_row.observed.get("observed", obs_row.observed) if isinstance(obs_row.observed, dict) else {}
    config = data.get("config") if isinstance(data, dict) else None
    if not isinstance(config, list):
        return []
    paths = []
    for entry in config:
        if isinstance(entry, dict) and entry.get("path"):
            paths.append(str(entry["path"]))
    return paths


def _drift_count(obs_row: AgentObservedState | None) -> int:
    if obs_row is None or not obs_row.drift:
        return 0
    drift = obs_row.drift
    if isinstance(drift, dict):
        d = drift.get("drift")
        if isinstance(d, list):
            return len(d)
    return 0


async def build_cards(session: AsyncSession) -> list[Card]:
    """Compose one-or-more knowledge cards per enrolled host from the current DB."""
    agents = (await session.scalars(
        select(Agent).where(Agent.enrollment_state == "enrolled").order_by(Agent.name)
    )).all()
    if not agents:
        return []
    by_id = {a.id: a for a in agents}

    obs_rows = (await session.scalars(select(AgentObservedState))).all()
    obs_by_agent = {row.agent_id: row for row in obs_rows}

    services = (await session.scalars(select(Service))).all()
    svc_by_agent: dict = {}
    for s in services:
        svc_by_agent.setdefault(s.agent_id, []).append(s)

    edges = (await session.scalars(select(HostEdge).order_by(HostEdge.event_count.desc()))).all()
    edge_by_src: dict = {}
    for e in edges:
        edge_by_src.setdefault(e.src_agent_id, []).append(e)

    cards: list[Card] = []
    for agent in agents:
        aid = str(agent.id)
        svcs = svc_by_agent.get(agent.id, [])
        ok = sum(1 for s in svcs if s.state == "OK")
        warn = [s for s in svcs if s.state == "WARN"]
        crit = [s for s in svcs if s.state == "CRIT"]
        obs_row = obs_by_agent.get(agent.id)
        drift = _drift_count(obs_row)
        paths = _config_paths(obs_row)

        # ── host identity + health ──────────────────────────────────────────
        lines = [
            f"Host {agent.name} (address {agent.address or 'none'}). "
            f"Agent version {agent.agent_version or 'unknown'}, mode {agent.mode}, {agent.enrollment_state}.",
        ]
        fs = _facts_summary(agent.facts or {})
        if fs:
            lines.append(fs + ".")
        meta = []
        if agent.site:
            meta.append(f"site {agent.site}")
        if agent.criticality:
            meta.append(f"criticality {agent.criticality}")
        if agent.groups:
            meta.append(f"groups {', '.join(agent.groups)}")
        if agent.tags:
            meta.append("tags " + ", ".join(f"{k}={v}" for k, v in agent.tags.items()))
        if meta:
            lines.append("; ".join(meta) + ".")
        lines.append(
            f"Monitoring: {ok} OK, {len(warn)} WARN, {len(crit)} CRIT service(s). "
            f"Config drift: {drift} file(s) differ from desired."
        )
        if paths:
            lines.append("Managed/observed config files: " + ", ".join(paths[:20]) + ".")
        cards.append(Card(
            doc_id=f"host:{aid}", kind="host", ref_id=aid, host_id=aid,
            title=f"Host {agent.name}", text=_clip("\n".join(lines))))

        # ── current problems (only when there are any) ──────────────────────
        problems = crit + warn
        if problems:
            plines = [f"Current problems on host {agent.name}:"]
            for s in problems[:20]:
                val = f" = {s.value}" if s.value is not None else ""
                out = f" — {s.output.strip()[:160]}" if s.output else ""
                plines.append(f"- {s.name} ({s.metric}) is {s.state}{val}{out}")
            cards.append(Card(
                doc_id=f"problems:{aid}", kind="problems", ref_id=aid, host_id=aid,
                title=f"Problems on {agent.name}", text=_clip("\n".join(plines))))

        # ── network topology (who this host talks to) ──────────────────────
        host_edges = edge_by_src.get(agent.id, [])
        if host_edges:
            tlines = [f"Network connections from host {agent.name} (what it talks to):"]
            for e in host_edges[:20]:
                dst_name = by_id[e.dst_agent_id].name if e.dst_agent_id in by_id else str(e.dst_addr)
                lat = f", p99 {e.latency_ms_p99:.0f}ms" if e.latency_ms_p99 is not None else ""
                tlines.append(
                    f"- {e.src_comm} → {dst_name}:{e.dst_port} (seen {e.event_count}x{lat})")
            cards.append(Card(
                doc_id=f"topology:{aid}", kind="topology", ref_id=aid, host_id=aid,
                title=f"Connections from {agent.name}", text=_clip("\n".join(tlines))))

    return cards


def _upsert(session: AsyncSession, existing: dict, card: Card, h: str,
            vec: list[float] | None, model: str) -> None:
    row = existing.get(card.doc_id)
    if row is None:
        session.add(KnowledgeEmbedding(
            doc_id=card.doc_id, kind=card.kind, ref_id=card.ref_id, host_id=card.host_id,
            title=card.title, text=card.text, content_hash=h,
            embedding=vec, model=(model if vec is not None else "")))
    else:
        row.kind, row.ref_id, row.host_id = card.kind, card.ref_id, card.host_id
        row.title, row.text, row.content_hash = card.title, card.text, h
        row.embedding, row.model = vec, (model if vec is not None else "")


async def reindex(session: AsyncSession, embedding_client: EmbeddingClient | None) -> dict:
    """Rebuild the knowledge index incrementally. Cards are ALWAYS stored (so the
    lexical fallback works); embeddings are added best-effort — if no embedding
    client is configured, or the embed endpoint is unreachable, cards persist
    WITHOUT a vector and the index degrades to lexical retrieval instead of
    failing. Only new/changed cards are processed (content-hash short-circuit);
    vanished cards are pruned. Returns stats."""
    model = embedding_client.model if embedding_client else ""
    cards = await build_cards(session)

    existing = {
        row.doc_id: row for row in (await session.scalars(select(KnowledgeEmbedding))).all()
    }
    seen: set[str] = set()
    todo: list[tuple[Card, str]] = []
    unchanged = 0
    for card in cards:
        seen.add(card.doc_id)
        h = _hash(card.text)
        row = existing.get(card.doc_id)
        # Up to date only if the text is unchanged AND it already carries a vector
        # from the CURRENT model (so a newly-available embed model re-vectorises
        # text-only rows on the next run).
        if row is not None and row.content_hash == h and (
            embedding_client is None or (row.embedding is not None and row.model == model)
        ):
            unchanged += 1
            continue
        todo.append((card, h))

    embedded = 0
    stored_text_only = 0
    embeddings_available = embedding_client is not None
    for start in range(0, len(todo), _EMBED_BATCH):
        batch = todo[start:start + _EMBED_BATCH]
        vectors: list[list[float]] | None = None
        if embeddings_available:
            try:
                vectors = await embedding_client.embed([c.text for c, _ in batch])
            except EmbeddingClientError as exc:
                embeddings_available = False  # stop trying; store the rest text-only
                logger.warning("knowledge reindex: embedding unavailable, storing text-only: %s", exc)
        for i, (card, h) in enumerate(batch):
            vec = vectors[i] if vectors else None
            _upsert(session, existing, card, h, vec, model)
            if vec is not None:
                embedded += 1
            else:
                stored_text_only += 1

    stale = [doc_id for doc_id in existing if doc_id not in seen]
    if stale:
        await session.execute(
            delete(KnowledgeEmbedding).where(KnowledgeEmbedding.doc_id.in_(stale)))

    await session.commit()
    stats = {
        "total": len(cards), "embedded": embedded, "stored_text_only": stored_text_only,
        "unchanged": unchanged, "pruned": len(stale), "embeddings_available": embeddings_available,
    }
    logger.info("knowledge reindex: %s", stats)
    return stats


async def maybe_reindex(session_factory: async_sessionmaker[AsyncSession], settings: Settings) -> None:
    """Called from the poller each cycle; actually reindexes only once per
    knowledge_reindex_interval_seconds. Best-effort embedding (falls back to
    text-only cards when no embed endpoint is reachable)."""
    global _last_reindex
    if not settings.knowledge_index_enabled:
        return
    now = datetime.now(timezone.utc)
    if _last_reindex is not None and (now - _last_reindex).total_seconds() < settings.knowledge_reindex_interval_seconds:
        return
    _last_reindex = now
    embedding_client = embedding_client_for(settings)
    async with session_factory() as session:
        await reindex(session, embedding_client)
