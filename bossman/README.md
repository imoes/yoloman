# Bossman

Fleet Commander for `agentic-mcpd` ("Duppy") node agents — see
[`docs/plan.md`](../docs/plan.md) in the repo root for the full design.

## Develop

```bash
uv sync
uv run pytest
uv run ruff check .
```

## Local dev database

Bossman needs a Postgres instance with the TimescaleDB extension. For local
development:

```bash
docker run -d --name bossman-dev-db -p 55432:5432 \
  -e POSTGRES_USER=bossman -e POSTGRES_PASSWORD=bossman -e POSTGRES_DB=bossman \
  timescale/timescaledb:latest-pg16

export BOSSMAN_DATABASE_URL="postgresql+asyncpg://bossman:bossman@localhost:55432/bossman"
uv run alembic upgrade head
```

The `timescale/timescaledb:latest-pg16` image already bundles the `vector`
extension (pgvector) used by the chunk-similarity cache below — `alembic
upgrade head` enables it (`CREATE EXTENSION IF NOT EXISTS vector`), no
different image or dev-DB recreation needed.

## Chunk-similarity embedding cache

A fuzzy, additive layer on top of `services/plan_loader.py`'s exact
`chunk_id`/`source_hash` comparison (see `docs/plan.md`'s "Chunk-similarity
embedding cache" section): `POST /api/v1/chunks/index` embeds and persists a
translated chunk's foreign source text; `POST /api/v1/chunks/similar` finds
already-indexed chunks whose source is a close (cosine-similar) match,
suggesting reuse instead of re-translating from scratch. Configuration
(env vars, `BOSSMAN_` prefix):

| Variable | Default | Meaning |
|---|---|---|
| `BOSSMAN_EMBEDDING_BASE_URL` | `https://llm.example.internal/embed` | OpenAI-compatible `/v1/embeddings` endpoint |
| `BOSSMAN_EMBEDDING_MODEL` | `bge-m3` | Model name passed in the request body |
| `BOSSMAN_EMBEDDING_DIM` | `1024` | Expected vector width (must match the DB column and the model) |
| `BOSSMAN_EMBEDDING_TOKEN` | `""` | Bearer token, if the endpoint requires one |
| `BOSSMAN_CHUNK_SIMILARITY_THRESHOLD` | `0.85` | Cosine-similarity cutoff for a reuse suggestion |

## Run

```bash
uv run uvicorn bossman.main:app --reload
```
