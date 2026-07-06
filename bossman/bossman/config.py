"""Bossman configuration, loaded from environment variables (and an
optional .env file for local development) via pydantic-settings.

Deliberately environment-variable-based rather than a YAML file like the
Go node agent's config.yaml: Bossman is meant to run as a container/
systemd service in the same conventional way this team's other Python
services do, where env vars are the normal configuration channel.
"""

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="BOSSMAN_", env_file=".env", extra="ignore")

    # Postgres/TimescaleDB connection string, e.g.
    # "postgresql+asyncpg://bossman:secret@localhost:5432/bossman".
    database_url: str = "postgresql+asyncpg://bossman:bossman@localhost:5432/bossman"

    # Shared bootstrap secret for the enrollment handshake (see
    # internal/enroll on the Go side) — the only auth possible before any
    # per-agent trust exists.
    enroll_secret: str = ""

    # The address a node agent (Duppy) actually reaches this Bossman at to
    # run `agentic-mcpd register --enroll-url ...` — deliberately separate
    # from any browser-facing UI URL (which may go through a reverse proxy
    # on a different port/host entirely). Surfaced by GET /api/v1/enroll/info
    # for the Settings page's copy-pasteable register command; left empty
    # by default since only the operator knows the real externally-
    # reachable address for their deployment.
    public_url: str = ""

    # Bossman's own TLS client keypair (presented to every node agent it
    # polls, pinned by each agent's tls.trusted_client_keys), persisted so
    # it survives restarts rather than being regenerated on every boot.
    client_key_path: str = "/etc/bossman/tls/bossman-client.key"
    client_cert_path: str = "/etc/bossman/tls/bossman-client.crt"

    # Where plan YAML files live (see docs/plan.md's plan-format design).
    plans_dir: str = "/etc/bossman/plans"

    # The Starlark module library (docs/plan.md Blocks G7/G8): translated
    # collection modules land here as <collection>/<name>.{yaml,star},
    # written by the submit_module MCP tool.
    modules_dir: str = "/etc/bossman/modules.d"
    # Pre-dumped Ansible module sources (argspec + original Python) that
    # get_module_source serves as the translation template — generated on
    # a host with ansible + the collections installed (see
    # scripts/dump_module_sources.py), mounted read-only here.
    module_sources_dir: str = "/etc/bossman/module_sources"
    # The starlark-check validator binary (Go, cmd/starlark-check) that
    # validate_module/submit_module shell out to.
    starlark_check_path: str = "starlark-check"

    # Polling interval for the metrics/connection-edges poller.
    poll_interval_seconds: int = 60

    # Max agents polled concurrently — bounded via asyncio.Semaphore rather
    # than a task queue (Celery/Redis); comfortably sufficient at this
    # project's targeted fleet size (~100 hosts, see docs/plan.md).
    poll_concurrency: int = 10

    # JWT signing secret for the human-operator dashboard login.
    jwt_secret: str = ""
    jwt_algorithm: str = "HS256"
    jwt_ttl_minutes: int = 720

    # Origins allowed to call this API cross-origin — the Angular
    # frontend (bossman-ui) is served from its own dev-server port (and,
    # depending on deployment, its own production origin too), so without
    # this the browser's CORS preflight silently blocks every request
    # carrying an Authorization header or JSON body (a real bug found
    # while first wiring bossman-ui's login against a real running
    # Bossman — see docs/plan.md's Bossman Block C notes). Defaults cover
    # the Angular CLI's default dev-server ports.
    cors_allowed_origins: list[str] = ["http://localhost:4200", "http://localhost:4300"]

    # OpenAI-compatible embedding endpoint used for the chunk-similarity
    # cache (see docs/plan.md's "Chunk-similarity embedding cache"): a
    # fuzzy, additive layer on top of plan_loader's exact source_hash
    # comparison, for source chunks that don't hash-match anything already
    # translated. embedding_token is "" when the endpoint requires no auth
    # (true for the current bge-m3 deployment).
    embedding_base_url: str = "https://llm.example.internal/embed"
    embedding_model: str = "bge-m3"
    embedding_dim: int = 1024
    embedding_token: str = ""

    # Cosine-similarity cutoff for find_similar_chunks: a candidate below
    # this is considered unrelated, not a reuse suggestion.
    chunk_similarity_threshold: float = 0.85

    # Cosine-similarity cutoff for search_plans (see docs/plan.md's
    # "Plan-catalog RAG") — deliberately its OWN, lower value, not
    # chunk_similarity_threshold: real bge-m3 measurements against short
    # plan-name+description text put genuine matches at ~0.79-0.85 and
    # genuine non-matches at ~0.66-0.73, a much narrower band than whole
    # Ansible-task-file chunks. Reusing 0.85 here would reject real matches.
    plan_search_threshold: float = 0.75

    # OpenAI-compatible chat-completions endpoint used by the real LLM
    # translator (see docs/plan.md's "real LLM translator" and
    # services/translator.py) — a different model/path on the same host as
    # the embedding endpoint above (qwen3next-79b, completion-only; it does
    # NOT serve embeddings itself, confirmed by probing it directly).
    chat_base_url: str = "https://llm.example.internal/qwen79b"
    chat_model: str = "qwen3next-79b"
    chat_token: str = ""


def get_settings() -> Settings:
    return Settings()
