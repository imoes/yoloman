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

## Run

```bash
uv run uvicorn bossman.main:app --reload
```
