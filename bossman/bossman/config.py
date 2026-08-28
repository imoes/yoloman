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

    # ── Agent release channel (GitHub) ──────────────────────────────────────
    # Where the yoloman-agent package is published. Bossman polls this repo's
    # latest release (its manifest.json carries each asset's SHA-256), so it can
    # detect a NEW package by hash + version and offer a one-click rollout that
    # pushes the verified .deb/.rpm to enrolled hosts via the self-update channel.
    agent_release_repo: str = "imoes/yoloman"
    agent_release_enabled: bool = True
    # How often the poller re-checks the release channel (seconds).
    agent_release_check_interval_seconds: int = 3600
    # Optional GitHub token — only needed for a private repo or to avoid the
    # unauthenticated API rate limit. A public repo works without it.
    github_token: str = ""

    # ── Infra knowledge index (RAG) ─────────────────────────────────────────
    # The poller periodically rebuilds a semantic+lexical knowledge index over
    # the live fleet (services/knowledge_index.py) so the assistant can answer
    # grounded questions ("ask the infrastructure"). Incremental (content-hash),
    # and it degrades to lexical retrieval when no embedding endpoint is present
    # — so it never hard-depends on the vector DB / embed model.
    knowledge_index_enabled: bool = True
    knowledge_reindex_interval_seconds: int = 600
    # The address:port the deployed agent listens on (0.0.0.0 so Bossman can
    # reach it) and the value stored as the Agent row's address (host:port).
    agent_listen_port: int = 18051
    # Whether a freshly-deployed agent gets the master write gate enabled.
    # Default TRUE: a PXE-provisioned host comes up write-enabled so its assigned
    # roles converge without a manual opt-in. Per deployment it can be overridden
    # (PlannedHostIn.write / the `agentic-mcpd register --write=false` flag), and
    # writes can always be toggled later via the self-config carve-out.
    agent_deploy_write: bool = True

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
    # What each config file says ABOUT ITSELF: files whose own header declares them machine-written
    # ("DO NOT EDIT THIS FILE", "Please don't edit this example config file"), recorded by
    # scripts/find_generated_files.py from the shipped bytes. Editing those by field is not forbidden —
    # it is a trap worth naming, because the next generator run discards the change and the drift comes
    # back with no visible cause. Read-only; served so the editors can quote the file's own sentence.
    config_generated_path: str = "/app/configs/config_generated.json"
    # Whether the path EXISTS as a file in the package that claims it — measured by extracting the real .deb
    # (scripts/verify_registry_paths.py, recorded by scripts/record_path_verdicts.py). A different question
    # from the codec registry's: that one answers how a file is written, this one whether there is a file.
    # 2248 registry entries have a path that is exactly their package's own name (/etc/bind, /etc/aide,
    # /etc/ttygif) and the measured ones are overwhelmingly absent — offered until now as config files to
    # edit, 1342 of them with confidence "high". Read-only; served so a screen can say so instead of
    # opening an editor on nothing.
    config_path_verdicts_path: str = "/app/configs/config_path_verdicts.json"
    # What happened when a claimed codec was TESTED against the file the package ships
    # (scripts/decide_codecs.py --record). Distinguishes "nobody has looked" from "looked, and the file could
    # not decide": all 81 unmeasured claims with a real file in the corpus came back no-evidence, because the
    # shipped copy of /etc/security/limits.conf and friends is entirely comments. The first is a task, the
    # second is a dead end for this method — and they were indistinguishable in the API.
    codec_probe_verdicts_path: str = "/app/configs/codec_probe_verdicts.json"
    # Block 3: the co-located poller agent that runs SNMP checks on behalf of
    # agent-less devices (see project-ssh-snmp-checks). SNMP devices are created
    # as satellites of this agent.
    # The built bossman-ui, served by this app when the directory exists. Empty (the default) means
    # "somebody else serves it" — which is the DOCKER deployment, where an nginx container serves the SPA and
    # reverse-proxies /api/v1 here. The native .deb/.rpm has no nginx, so the package points this at
    # /opt/yoloman-bossman/ui and the whole console is reachable on one port. Two deployments, one app,
    # and the difference is a path rather than a second code path.
    ui_dir: str = ""

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
    # Lego capability inventory: derive what each host provides/requires from its installed roles x the
    # per-template capabilities.json, into host_capabilities. Pure DB read (facts + catalog), no agent
    # call; recompute alongside compliance. Off in tests. See services/capabilities.py.
    capabilities_enabled: bool = True
    capabilities_interval_seconds: int = 3600
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

    # Bare-metal deployment (PXE). The netboot helper is unauthenticated hardware: when it boots it
    # has no token, no certificate and no identity beyond its MAC address, yet it needs to be handed
    # an install plan. So it presents a shared secret that the PXE configuration puts on its kernel
    # command line.
    #
    # Empty by default, and empty means the check-in endpoint REFUSES — deploying this code must not
    # open anything by itself. Be clear-eyed about what the secret is worth: the PXE config is served
    # over TFTP without authentication, so anyone on that network segment can read it. It
    # distinguishes "a machine that netbooted from us" from "any host that can reach the API", which
    # is worth having, and it is not a substitute for the segment being a test network. Rotate it
    # when the segment changes.
    netboot_secret: str = ""
    # Where the captured images live, served to targets over HTTP by the netboot container.
    image_store_dir: str = "/etc/bossman/images"
    # The base URL a netbooted target uses to fetch images. Empty falls back to public_url, which is
    # the same address the agent enrolment uses.
    image_base_url: str = ""
    # PXE nested-virt lab (services/vm_lab.py): Bossman drives QEMU inside the pxe container via
    # `docker exec <pxe_container> vm-control.sh …` to install a template from an ISO or PXE-test a
    # target end-to-end. Empty pxe_container disables the /vm/* endpoints (they 503) — the deploy sets
    # it once the pxe profile is up. Needs the docker socket + docker CLI in the bossman image (Block 6).
    pxe_container: str = ""
    docker_bin: str = "docker"
    # Host the pxe container's per-VM websockify (noVNC) bridges listen on — the browser can't reach it
    # directly, so Bossman relays /vm/{name}/vnc to ws://<pxe_vnc_host>:<ws_port>. Defaults to the ens19
    # listen IP the lab binds to.
    pxe_vnc_host: str = "192.0.2.130"
    # L4: the clock a notification time period is read in. NOT UTC, and not the
    # container's local zone either: this container runs UTC (verified: host 18:30 CEST,
    # container 16:30 UTC), so an 08:00-17:00 "business hours" window silently reported
    # itself as active at 18:30 local. Checkmk evaluates in the site's local zone
    # (tzlocal()); we make it an explicit IANA name instead, because "the container's
    # zone" is an accident of the image while a window is a statement about the people
    # being paged. Any IANA name works, e.g. UTC for a follow-the-sun rota.
    time_period_timezone: str = "Europe/Berlin"

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

    # HTTP(S) proxy baked into a PXE-provisioned target so it can reach package mirrors + the internet
    # from its destination segment. Written into /etc/environment and every package manager's config
    # (apt/dnf/yum/zypper) during the restore's target phase. Empty = no proxy written. no_proxy keeps
    # local/corp traffic direct (comma-separated). https falls back to http when unset.
    target_http_proxy: str = ""
    target_https_proxy: str = ""
    target_no_proxy: str = "localhost,127.0.0.1,::1"

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
    # EMPTY BY DEFAULT, like the three endpoint fields below it. These pointed at one company's internal
    # llama.cpp host, so a fresh clone of this repository tried to reach a machine nobody else has — and the
    # address of that machine was published with the source. An endpoint is per-installation configuration:
    # it belongs in docker-compose.override.yml (see the .example) or in the environment, and empty here
    # means "not configured", which is a state the callers already handle.
    embedding_base_url: str = ""
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
    chat_base_url: str = ""
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
    chat_backend: str = "hermes_web"  # claude_cli | codex | hermes_web | openrouter
    hermes_web_base_url: str = ""
    hermes_web_model: str = "laguna"
    # OpenRouter: OpenAI-compatible aggregator (function-calling identical), so it
    # reuses the hermes/OpenAI client. base_url is the /api root — the client
    # appends /v1/chat/completions. Token via env (never committed); model is any
    # OpenRouter model id (e.g. a small/cheap one to prove small models can drive
    # Bossman over MCP). Lets even tiny models run the fleet.
    openrouter_base_url: str = "https://openrouter.ai/api"
    # A SMALL, open, tool-capable model by default — verified to call Bossman's
    # MCP tools over OpenRouter (proves even tiny models can run the fleet). Any
    # OpenRouter model id whose providers support tool-use works; note some models
    # (e.g. nousresearch/hermes-3) have NO tool-use endpoint and 404 on tools.
    openrouter_model: str = "qwen/qwen-2.5-7b-instruct"
    openrouter_token: str = ""
    # Model used to extract configurable variables from Docker Hub READMEs
    # (services/docker_readme) via the OpenRouter backend. Overridable with
    # BOSSMAN_DOCKER_EXTRACT_MODEL.
    docker_extract_model: str = "poolside/laguna-s-2.1"
    # SearXNG metasearch (co-located with the LLM host) — backs the package-doc
    # verification batch and the web_search MCP tool.
    searxng_base_url: str = ""
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
    # host_edges is a PLAIN table (no hypertable retention policy), and it only ever upserted — so it kept
    # claiming a relationship long after the agent that reported it had forgotten: the agent prunes its own
    # connection_edges at its raw-retention cutoff, 24h by default (internal/store/sqlite.go pruneEdges).
    # A view that outlives its source states a relationship nothing can still observe. 30 days is Bossman's
    # own, longer history — deliberately not the agent's 24h, since the point of the copy is to remember
    # more than the host can, only not forever. Enforced in services/housekeeping.run_housekeeping.
    host_edges_retention_days: int = 30
    # Out-of-band (drift) auditing via the host's auditd (services/external_audit).
    # OFF by default: when on, the poller opportunistically installs audit watch
    # rules on each host's managed config files and ingests hand-edits into the
    # audit trail. Off by default because enabling it WRITES audit rules onto the
    # host — an opt-in the operator turns on (BOSSMAN_EXTERNAL_AUDIT_ENABLED=true).
    external_audit_enabled: bool = False
    # Don't re-run the (auditd setup + ausearch) scan on every poll — throttle it.
    external_audit_interval_seconds: int = 900
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
    # Event-driven self-healing: run RemediationPolicy runbooks when a check goes
    # hard on the poll path. Off in the test suite (like the poller loops).
    remediation_enabled: bool = True
    # Master kill-switch for AUTONOMOUS remediation (Phase 2). Even a policy set to
    # autonomy=auto_verify only runs unattended when this is on — off by default so
    # the fleet must explicitly opt into any self-applied change.
    remediation_autonomy_enabled: bool = False
    # Wake the reconciler INSTANTLY on a change via Postgres LISTEN/NOTIFY, instead
    # of waiting up to reconcile_interval_seconds. enqueue_policy_event fires a
    # NOTIFY in the same transaction (delivered on commit); a dedicated listener
    # connection wakes the loop. Pure optimisation — the outbox is still the
    # durable truth and reconcile_interval_seconds remains the fallback/backoff
    # poll — so it degrades cleanly to interval polling if the listener drops.
    reconcile_listen_notify: bool = True
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
