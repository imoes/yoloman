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

    # Enrollment is open — there is no enroll secret. The agent registers,
    # receives Bossman's public key, and is added to the inventory; the
    # authenticated way to add a host is the server-driven SSH deploy.

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

    # Secrets vault (services/vault.py): the Fernet key used to encrypt
    # sensitive variable values at rest (no plaintext passwords in the DB).
    # When vault_key is empty, a key is generated once and persisted to
    # vault_key_path, so a restart keeps the same key and existing ciphertexts
    # stay decryptable — mirroring the TLS keypair above.
    vault_key: str = ""
    vault_key_path: str = "/etc/bossman/vault.key"

    # Server-driven SSH deploy (Block N-enroll): Bossman connects to a new
    # host over SSH with a PRE-CONFIGURED operator identity, installs the
    # agent .deb, and provisions a complete config.yaml (token + Bossman's
    # pinned public key + TLS) itself — so no enrollment secret is needed
    # (the SSH channel IS the root of trust; there is nothing else to
    # protect). All empty by default → the deploy field stays hidden until
    # an operator configures it. deploy_ssh_key_path wins over
    # deploy_ssh_password when both are set; deploy_sudo_password falls back
    # to deploy_ssh_password for the `sudo -S` that installs the package.
    deploy_ssh_user: str = ""
    deploy_ssh_password: str = ""
    deploy_ssh_key_path: str = ""
    deploy_sudo_password: str = ""
    deploy_ssh_port: int = 22
    # Path (inside the Bossman container/host) to the agent .deb that gets
    # copied to and installed on each freshly-deployed host.
    agent_deb_path: str = ""
    # The matching RPM for RHEL/Fedora/SUSE hosts — the bundled self-update
    # picks .deb vs .rpm by the target's OS family.
    agent_rpm_path: str = ""
    # The address:port the deployed agent listens on (0.0.0.0 so Bossman can
    # reach it) and the value stored as the Agent row's address (host:port).
    agent_listen_port: int = 18051
    # Whether a freshly-deployed agent gets the master write gate enabled.
    # Default false: a new host is monitor-only until an operator opts it in.
    agent_deploy_write: bool = False

    # Where plan YAML files live (see docs/plan.md's plan-format design).
    plans_dir: str = "/etc/bossman/plans"
    # Block K2: the Class-B config template library (configs/config_templates/
    # in the repo), each a <name>/ dir with template.j2 + schema.json +
    # sample.json. Served as a catalog and bound to discovered config files.
    config_templates_dir: str = "/app/config-templates"
    # F-8: the man-page-derived codec registry (configs/config_codecs.json in
    # the repo, also go:embedded in the agent). Read-only; served as a catalog
    # so an operator can see how each config file's grammar is read/written.
    config_codecs_path: str = "/app/config_codecs.json"
    # ADMX equivalent: per-directive value catalog (configs/config_directives.json,
    # mined by scripts/mine_directive_values.py) so the gpedit editor offers real
    # per-directive listboxes. Read-only.
    config_directives_path: str = "/app/config_directives.json"
    # Block 3: the co-located poller agent that runs SNMP checks on behalf of
    # agent-less devices (see project-ssh-snmp-checks). SNMP devices are created
    # as satellites of this agent.
    poller_agent_name: str = "bossman-poller"

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

    # The check library (Block G9): every monitoring check — translated from
    # Checkmk or hand-authored ("custom checks") — lands here FLAT as
    # <name>.{star,yaml}, unlike modules.d's per-collection layout. A check is
    # a read-only Starlark module (writes:false) returning a monitoring
    # verdict in `data` (state/metrics); see services/checkmk_translation.py.
    checks_dir: str = "/etc/bossman/checks.d"

    # Checkmk's discovery inputs (check -> sections, section -> which platform's
    # agent emits it), generated by scripts/extract_checkmk_sections.py. Lets
    # discovery ask Checkmk's own question — "could this host produce this
    # check's data" — before running anything. A missing file disables the gate
    # rather than narrowing discovery silently.
    checkmk_sections_path: str = "/etc/bossman/checkmk_sections.json"

    # Help/docs (Block G10): the README.md (+ docs/) mounted here are served as
    # the in-app Help page, searched by the AI's search_help tool, and used as
    # the model's fallback context when it's unsure about the product.
    help_root: str = "/etc/bossman/help"

    # Seed the built-in-check default rules (Memory/Disk) at startup (Block
    # H6). Disabled in the test suite so the seeded global rules don't
    # pollute the shared test database's count-based assertions.
    seed_default_checks: bool = True

    # Master switch for the background poller (mirrors housekeeping_enabled)
    # — disabled in the test suite (see tests/conftest.py) so a TestClient's
    # real app lifespan doesn't run real network/DB work concurrently with
    # whatever the test itself is doing on the shared event loop. A real
    # bug this surfaced: AgentClient's httpx.AsyncClient(cert=...) raising a
    # bare OSError for a missing cert file used to escape every per-agent
    # try/except (fixed separately, services/agent_client.py) — but even
    # with that fixed, letting the poller touch the DB for real during
    # every API test was needless concurrency the tests never asked for.
    poll_enabled: bool = True
    # Master switch for the recurring-runbook scheduler loop (off in tests, like
    # poll_enabled — a real scheduler tick would run runbooks against hosts).
    scheduler_enabled: bool = True
    # Event Console (gap #2): passive receipt of syslog + SNMP traps. Ports are
    # high by default (privileged 514/162 need a container port-map or CAP_
    # NET_BIND_SERVICE); off in tests. See services/event_console.py.
    event_console_enabled: bool = True
    syslog_listen_port: int = 1514
    snmptrap_listen_port: int = 1162
    event_console_host: str = "0.0.0.0"
    # Software-compliance evaluation (gap #9): required/forbidden packages per
    # scope, alert on drift. Reads Agent.facts["installed_packages"]; off in
    # tests. See services/compliance.py.
    compliance_enabled: bool = True
    compliance_interval_seconds: int = 3600
    # Audit trail (gap #13): record authenticated mutating API calls + logins.
    # Off in tests (keeps the test DB's mutations out of the trail).
    audit_enabled: bool = True
    # Business/logical service aggregation (gap #4): roll a state up from many
    # underlying services. Cheap (reads DB state); recompute ~every minute.
    business_service_enabled: bool = True
    business_service_interval_seconds: int = 60
    # Polling interval for the metrics/connection-edges poller.
    poll_interval_seconds: int = 60
    # L1: a metric older than staleness_factor x poll_interval_seconds is no longer a
    # statement about now, so the service goes UNKNOWN ("no data for X") instead of
    # being judged on a dead host's last reading. Checkmk's equivalent
    # staleness_threshold defaults to 1.5, but its core produces the result at check
    # time (age ~ 0), whereas ours crosses agent-sample -> poll -> evaluate. Measured
    # on the live fleet: healthy hosts sit at 61-108 s, worst sample gap 120 s — so
    # 1.5 (90 s) would flag healthy hosts. See monitoring.stale_after_for().
    staleness_factor: float = 4.0

    # Max agents polled concurrently — bounded via asyncio.Semaphore rather
    # than a task queue (Celery/Redis); comfortably sufficient at this
    # project's targeted fleet size (~100 hosts, see docs/plan.md).
    poll_concurrency: int = 10

    # CVE feed cache (Block 4): periodically fetch distro security trackers and
    # index them so pending package updates can be correlated to the CVEs they
    # fix. Disabled by default so tests/offline runs don't reach the internet.
    cve_feed_enabled: bool = False
    cve_feed_interval_hours: int = 24
    cve_cache_dir: str = "/etc/bossman/cve-cache"
    # Overridable source URLs (corporate proxy / mirror).
    cve_debian_url: str = "https://security-tracker.debian.org/tracker/data/json"
    cve_ubuntu_url: str = "https://ubuntu.com/security/notices.json"
    cve_redhat_url: str = "https://access.redhat.com/hydra/rest/securitydata/cve.json"

    # NOTE: the helm chart-pull proxy is NOT an env-var setting — it is DB-backed
    # and edited in Admin Settings (SystemSettings.helm_http_proxy / helm_no_proxy,
    # cached in services/helm_app). See api/system_settings.py.

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
    # the embedding endpoint above (laguna, completion-only; it does
    # NOT serve embeddings itself, confirmed by probing it directly).
    # Utility one-shot completions (ChatClient.complete_*, e.g. the run
    # dialog's AI briefing) and the translator go to the fast qwen35b — the
    # conversational console uses hermes_web/qwen79b below, which is often
    # overloaded for short, high-frequency utility calls.
    chat_base_url: str = "https://llm.example.internal/qwen35b"
    chat_model: str = "/models/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf"
    chat_token: str = ""

    # Block K — AI chat console. The docked chatbot routes a conversation to
    # one of three selectable backends; `chat_backend` is the default when a
    # request doesn't name one. hermes-web is OpenAI-compatible (its own
    # gateway server); codex hits ChatGPT's unofficial Codex endpoint with a
    # device-code OAuth token; claude_cli shells out to the local `claude`
    # binary (--print). Per-backend endpoints/models are configurable; auth
    # for claude_cli/codex is ambient (CLI login / cached OAuth token file).
    # Defaults point the console at the live OpenAI-compatible qwen79b endpoint
    # so it works out of the box; per-user overrides (endpoint + model) live in
    # the DB (chat_preferences), configured from the Settings → AI Assistant
    # card — not in the environment.
    chat_backend: str = "hermes_web"  # claude_cli | codex | hermes_web
    hermes_web_base_url: str = "https://llm.example.internal/laguna"
    hermes_web_model: str = "laguna"
    # SearXNG metasearch (co-located with the LLM host) — backs the package-doc
    # verification batch and the web_search MCP tool.
    searxng_base_url: str = "http://llm.example.internal:8080"
    hermes_web_token: str = ""
    codex_base_url: str = "https://chatgpt.com/backend-api/codex"
    codex_model: str = "gpt-5.5"
    claude_cli_path: str = "claude"
    claude_cli_model: str = "sonnet"
    # Root of per-user chat home dirs (bind-mounted). Each user gets
    # {chat_home_root}/{username}; the claude/codex CLIs store their OAuth
    # credentials there natively, and their subprocess runs with HOME set to it.
    chat_home_root: str = "/var/lib/bossman/chat-homes"

    # Notifications (Block H8): master switch + SMTP transport. Webhook
    # targets carry their own URL per rule, so need no global config. The
    # notifier fires on a confirmed (hard) problem onset/recovery, skipping
    # acknowledged / in-downtime / flapping services.
    notifications_enabled: bool = True
    smtp_host: str = ""
    smtp_port: int = 25
    smtp_from: str = "bossman@localhost"
    smtp_user: str = ""
    smtp_password: str = ""
    smtp_use_tls: bool = False
    # Per-send network timeout for SMTP + webhook (seconds).
    notify_timeout_seconds: float = 10.0

    # Housekeeping (Zabbix gap-analysis Block K1): notifications and
    # plan_runs previously had no retention at all (unbounded growth); they
    # now default to 90 days, actively enforced by services/housekeeping.py
    # (run on a timer and triggerable on demand via POST
    # /api/v1/admin/housekeeping/run).
    housekeeping_enabled: bool = True
    housekeeping_interval_seconds: int = 3600
    notifications_retention_days: int = 90
    plan_runs_retention_days: int = 90
    # Process (pid,comm) metric series with no fresh sample within this window
    # are treated as dead and deleted by housekeeping (a live process samples
    # every collect interval, ~60s). Runs on housekeeping_interval_seconds.
    # 1 minute: a dead pid must never survive into a compressed chunk (>1 day),
    # and the prune is cheap now that it no longer goes through an FK cascade.
    process_metric_stale_minutes: int = 1
    # How often the per-PID prune runs. This — not the threshold above — is what
    # actually bounds per-PID cardinality: with the sweep on the hourly
    # housekeeping tick, 1110 of 1448 process series were dead corpses waiting for
    # collection. Two minutes keeps the standing set close to the live processes.
    process_prune_interval_seconds: int = 120

    # Block L4: the desired-state reconciler (drains controller_outbox,
    # recompiles affected hosts, enqueues agent_config_delivery). Mirrors
    # poll_enabled/housekeeping_enabled — disabled in the test suite so the
    # background loop doesn't race per-test DB state.
    reconcile_enabled: bool = True
    reconcile_interval_seconds: int = 15
    # Config-distribution convergence sweep (gap #15): the backstop that pushes
    # any host whose compiled generation is ahead of what it last ACKed — catches
    # hosts down at push time, newly-enrolled hosts, and un-enqueued mutations.
    # Slower than the event-driven reconciler (recompiles every host). Off in tests.
    config_sync_enabled: bool = True
    config_sync_interval_seconds: int = 600

    # metrics/connection_events/service_state_history are TimescaleDB
    # hypertables with their OWN native add_retention_policy(...) background
    # jobs, registered at migration time — these three values are NOT
    # enforced by Python (an earlier version of this file claimed they were,
    # which was wrong: changing them here would have had no actual effect).
    # They exist purely as informational mirrors of the real DB-level
    # policy, read by the metrics tiered-resolution logic (Block K1b,
    # services/metrics_query.py) to decide when a requested time range needs
    # metrics_hourly/metrics_daily instead of raw metrics.
    # RRD-style tiering (mirrors Checkmk's RRA cascade — cmk/rrd/_const.py):
    # 2 days at full 30s resolution, then 5-min / hourly / daily downsamples.
    # metrics_daily is built FROM metrics_hourly (hierarchical), so raw only
    # has to survive long enough to feed the 5-min/hourly tiers (~hours).
    metrics_retention_days: int = 2
    metrics_5min_retention_days: int = 10
    metrics_hourly_retention_days: int = 90
    metrics_daily_retention_days: int = 365
    connection_events_retention_days: int = 30
    service_state_history_retention_days: int = 30


def get_settings() -> Settings:
    return Settings()
