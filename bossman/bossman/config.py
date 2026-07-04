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

    # Bossman's own TLS client keypair (presented to every node agent it
    # polls, pinned by each agent's tls.trusted_client_keys), persisted so
    # it survives restarts rather than being regenerated on every boot.
    client_key_path: str = "/etc/bossman/tls/bossman-client.key"
    client_cert_path: str = "/etc/bossman/tls/bossman-client.crt"

    # Where plan YAML files live (see docs/plan.md's plan-format design).
    plans_dir: str = "/etc/bossman/plans"

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


def get_settings() -> Settings:
    return Settings()
