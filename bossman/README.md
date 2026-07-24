# Bossman

![Bossman — Linux Solutions](../docs/assets/bossman.jpg)

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

## Plan-catalog RAG

`POST /api/v1/plans/search` (and the MCP tool `search_plans`) find the few relevant
plans for a natural-language query by embedding every plan's name+description —
an alternative to scanning the full `catalog_markdown`/`list_plans` dump once the
catalog grows past a handful of plans. Re-indexes automatically on each call
(cheap after the first, via a content-hash short-circuit), no separate reindex
step needed.

| Variable | Default | Meaning |
|---|---|---|
| `BOSSMAN_PLAN_SEARCH_THRESHOLD` | `0.75` | Cosine-similarity cutoff — deliberately lower than the chunk threshold, calibrated against real short plan-description text |

Calibration note (measured against the real endpoint): similarity depends on how
much of a plan's description a query's wording actually overlaps — a short query
against a long, detailed description scores lower than one that echoes more of
the description's own content. If a query isn't finding an expected plan, try a
more specific query or pass an explicit lower `threshold` in the request.

## Real LLM translator

`POST /api/v1/translate` translates one foreign source file (e.g. an Ansible task
file) into a Bossman plan chunk via a real LLM call, with the response
grammar-constrained to a JSON schema (`response_format: json_schema`) so the
model can't produce structurally invalid output — `services/plan_loader.parse_plan`
is the sole semantic validation gate, retried with the validation error fed back
to the model on failure. Checks the chunk-similarity cache first; a close match
short-circuits the LLM call entirely. REST-only, no MCP tool — this is an
authoring-time action for a human/CI to review before a plan file is committed,
not a runtime fleet-management action.

| Variable | Default | Meaning |
|---|---|---|
| `BOSSMAN_CHAT_BASE_URL` | `https://llm.example.internal/laguna` | OpenAI-compatible `/v1/chat/completions` endpoint |
| `BOSSMAN_CHAT_MODEL` | `laguna` | Model name passed in the request body |
| `BOSSMAN_CHAT_TOKEN` | `""` | Bearer token, if the endpoint requires one |

Scoped to module-call steps only in this first increment — `pipeline:`/`upload:`
steps and `final_handler:` still need to be added by hand afterward, same as
`img_docker.yaml`'s own translation. `KNOWN_MODULES` in `services/translator.py`
constrains the `module` field to Bossman's actual implemented module set
(kept in sync by hand with `internal/modules/*.go`) — the model can't hallucinate
a module Bossman doesn't have, but it can still use an Ansible parameter alias
Bossman's own module doesn't implement (e.g. `pkg` instead of `name` for `apt`);
review translator output before committing it as a real plan.

## Run

```bash
uv run uvicorn bossman.main:app --reload
```
