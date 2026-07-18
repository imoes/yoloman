"""SQLAlchemy 2.0 declarative models for Bossman's schema (see
docs/plan.md's Bossman plan, section B.2).

Two of these tables (`metrics`, `connection_events`) are TimescaleDB
hypertables and `metrics_hourly` is a continuous aggregate — none of that
is expressible via SQLAlchemy's own DDL, so the hypertable/continuous-
aggregate/retention-policy calls live as raw SQL in the Alembic migration
that creates these tables, not here. The models below only describe the
plain relational shape each table has either way.
"""

import uuid
from datetime import datetime

from pgvector.sqlalchemy import Vector
from sqlalchemy import (
    Boolean,
    BigInteger,
    CheckConstraint,
    DateTime,
    Float,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
    text,
)
from sqlalchemy.dialects.postgresql import ARRAY, INET, JSONB, UUID
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship
from sqlalchemy.sql import func
from sqlalchemy.types import UserDefinedType


class LTREE(UserDefinedType):
    """Minimal SQLAlchemy binding for PostgreSQL's `ltree` type (Block L3a) —
    the OU tree's materialized label-path (e.g. Germany.Munich.Prod), stored
    alongside the human-readable varchar `path`. Values move as plain strings
    in Python; the actual ancestor/descendant queries (@>/<@) are issued as
    explicit text() SQL in services/compiler.py, so this type only needs to
    name the column type for DDL/reflection."""

    cache_ok = True

    def get_col_spec(self, **kw) -> str:  # noqa: ARG002
        return "ltree"

# Embedding dimension for the chunk-similarity cache's vector column (see
# docs/plan.md's "Chunk-similarity embedding cache") — the bge-m3 model
# behind the currently configured embedding endpoint. A column type can't
# read Settings at import time, so this is a plain constant, matching the
# migration's own hardcoded `vector(1024)`; switching embedding models
# means updating both together and re-embedding everything, since vectors
# from different models aren't comparable.
CHUNK_EMBEDDING_DIM = 1024

# The fixed, well-known UUID for the seeded default tenant (Block L1) —
# must match the literal in the b3f1a2c9d740 migration exactly, since both
# the DB-level server_default below and the migration's INSERT/UPDATE
# reference the same row.
DEFAULT_TENANT_ID = "00000000-0000-0000-0000-000000000001"

# The fixed, well-known UUID for the one-and-only SystemSettings row
# (Block L2) — must match the literal in the c7e4d81a9f52 migration.
SYSTEM_SETTINGS_ID = "00000000-0000-0000-0000-0000000000f1"

# Every timestamp column in this schema is timezone-aware (Postgres
# TIMESTAMPTZ) — a fleet spans hosts in different timezones, and comparing/
# bucketing naive timestamps across them would be silently wrong. Found by
# a real, failing integration test (see tests/test_models.py) rather than
# assumed: SQLAlchemy's plain DateTime() defaults to TIMESTAMP WITHOUT TIME
# ZONE, which asyncpg then refuses to bind an aware Python datetime into.
TZ_DATETIME = DateTime(timezone=True)


class Base(DeclarativeBase):
    pass


class Agent(Base):
    """One enrolled node agent ("Duppy")."""

    __tablename__ = "agents"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    name: Mapped[str] = mapped_column(String, unique=True, nullable=False)
    address: Mapped[str | None] = mapped_column(String)
    token: Mapped[str] = mapped_column(String, nullable=False)
    # Operational role from Bossman's view: a managed agent is a Duppy
    # (satellite) or a Selecta (proxy, fronts satellites). "standalone" means
    # un-enrolled/self-managed (bearer-only, no Bossman) — never stored for an
    # agent Bossman actually polls; the poller reclassifies on first contact.
    mode: Mapped[str] = mapped_column(String, nullable=False, default="satellite")
    enrollment_state: Mapped[str] = mapped_column(String, nullable=False, default="pending")
    enrolled_at: Mapped[datetime | None] = mapped_column(TZ_DATETIME)
    last_seen_at: Mapped[datetime | None] = mapped_column(TZ_DATETIME)
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)
    agent_metadata: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)

    # The host's HW/SW inventory document (CPU model, mainboard, serials,
    # BIOS, disks, NICs, OS — see the Go agent's internal/inventory and
    # docs/plan.md Block H2), refreshed from every hosts/overview poll.
    facts: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)
    facts_updated_at: Mapped[datetime | None] = mapped_column(TZ_DATETIME)

    # Per-resource poll cursors (see services/poller.py, Block B4): NULL
    # means "never successfully pulled yet" — the poller then omits the
    # from/since query parameter entirely and lets the agent apply its own
    # default range, rather than the poller inventing an arbitrary lookback
    # window. Two separate cursors, not one shared timestamp: metrics and
    # connection-edge dumps are independent REST calls that can fail
    # independently, and conflating them would let one silently mask gaps
    # in the other.
    last_metrics_pulled_at: Mapped[datetime | None] = mapped_column(TZ_DATETIME)
    last_edges_pulled_at: Mapped[datetime | None] = mapped_column(TZ_DATETIME)

    # Host-group membership (see docs/plan.md's monitoring Block E2) — the
    # CheckMK-style unit a check_rule can target instead of (or alongside)
    # a specific host. A host can belong to more than one group; rule
    # precedence (services/monitoring.resolve_effective_rule) is host >
    # group > global, with ties among multiple matching group rules broken
    # by most-recently-created.
    groups: Mapped[list[str]] = mapped_column(ARRAY(String), nullable=False, default=list)

    # Block K7 (Zabbix gap-analysis, tagging): name or name:value pairs,
    # e.g. {"env": "prod", "critical": ""} — inherited onto every problem
    # this host raises (see GET /api/v1/problems's `tag` filter) and
    # matchable by NotificationRule.tag_filter. Deliberately host-level
    # only for v1 (not also on individual triggers/items) — see
    # docs/zabbix-gap-analysis.md's Batch 3 for the narrower scope.
    tags: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)

    # Set when this agent was discovered as a satellite relayed through a
    # proxy's own GET /api/v1/hosts/overview (see services/poller.py and
    # docs/plan.md's monitoring-cockpit ergänzung Block F2) — NULL for a
    # directly enrolled standalone/proxy agent. This is what turns a
    # satellite from an invisible label buried in the proxy's metrics into
    # its own first-class host in the fleet view/topology.
    parent_agent_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), ForeignKey("agents.id"))

    # Policy/Orchestration layer (Block L1): additive only. tenant_id scopes
    # the host to a tenant (backfilled to the seeded default tenant by the
    # L1 migration); ou_id places it at exactly one node in the OU tree
    # (AD-style — multi-membership is via HostGroup, not multiple OUs). Both
    # nullable and ignored by every existing query — only the new compiler
    # (services/compiler.py) and the OU/orchestration REST routers read them.
    tenant_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="SET NULL"), server_default=text(f"'{DEFAULT_TENANT_ID}'::uuid")
    )
    ou_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), ForeignKey("ou_nodes.id", ondelete="SET NULL"))

    __table_args__ = (
        CheckConstraint("mode IN ('standalone', 'satellite', 'proxy')", name="ck_agents_mode"),
        CheckConstraint(
            "enrollment_state IN ('pending', 'enrolled', 'revoked')", name="ck_agents_enrollment_state"
        ),
    )


class HostEdge(Base):
    """Aggregated (process, destination) connection relationship — the
    durable, queried-by-dashboard/MCP view. See ConnectionEvent for the raw
    history this is derived from."""

    __tablename__ = "host_edges"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    src_agent_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("agents.id"), nullable=False)
    src_comm: Mapped[str] = mapped_column(String, nullable=False)
    dst_addr: Mapped[str] = mapped_column(INET, nullable=False)
    dst_port: Mapped[int] = mapped_column(Integer, nullable=False)
    dst_agent_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), ForeignKey("agents.id"))
    event_count: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    first_seen_at: Mapped[datetime] = mapped_column(TZ_DATETIME, nullable=False)
    last_seen_at: Mapped[datetime] = mapped_column(TZ_DATETIME, nullable=False)
    latency_ms_p50: Mapped[float | None] = mapped_column()
    latency_ms_p99: Mapped[float | None] = mapped_column()

    __table_args__ = (
        UniqueConstraint("src_agent_id", "src_comm", "dst_addr", "dst_port", name="uq_host_edges_identity"),
        Index("idx_host_edges_dst_agent", "dst_agent_id"),
        Index("idx_host_edges_last_seen", "last_seen_at"),
    )


class ConnectionEvent(Base):
    """Raw connection-state-transition history — a TimescaleDB hypertable
    (see the Alembic migration), pulled from each agent's own
    GET /api/v1/net/connections/dump."""

    __tablename__ = "connection_events"

    # No single-column primary key: TimescaleDB hypertables partition on
    # `time`, and a hypertable's unique/primary constraints must include
    # the partitioning column — simplest to just not declare one here and
    # let every row stand on its own (this is raw historical log data, not
    # something individual rows are ever updated/deleted by id).
    time: Mapped[datetime] = mapped_column(TZ_DATETIME, nullable=False, primary_key=True)
    src_agent_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("agents.id"), nullable=False, primary_key=True
    )
    pid: Mapped[int | None] = mapped_column(Integer)
    comm: Mapped[str | None] = mapped_column(String)
    src_addr: Mapped[str | None] = mapped_column(INET)
    src_port: Mapped[int | None] = mapped_column(Integer)
    dst_addr: Mapped[str | None] = mapped_column(INET)
    dst_port: Mapped[int | None] = mapped_column(Integer)
    old_state: Mapped[str | None] = mapped_column(String)
    new_state: Mapped[str | None] = mapped_column(String)

    __table_args__ = (Index("idx_conn_events_src_agent_time", "src_agent_id", "time"),)


class PlanRun(Base):
    """One execution of a named plan against one agent — the Ansible-
    replacement audit trail's parent row."""

    __tablename__ = "plan_runs"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    plan_name: Mapped[str] = mapped_column(String, nullable=False)
    plan_version: Mapped[str | None] = mapped_column(String)
    agent_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("agents.id"), nullable=False)
    params: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)
    dry_run: Mapped[bool] = mapped_column(nullable=False, default=False)
    status: Mapped[str] = mapped_column(String, nullable=False, default="running")
    started_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)
    finished_at: Mapped[datetime | None] = mapped_column(TZ_DATETIME)
    requested_by: Mapped[str | None] = mapped_column(String)

    steps: Mapped[list["PlanRunStep"]] = relationship(back_populates="plan_run", cascade="all, delete-orphan")

    __table_args__ = (
        CheckConstraint("status IN ('running', 'succeeded', 'failed', 'aborted')", name="ck_plan_runs_status"),
    )


class DeploymentRun(Base):
    """One multi-host deployment: a plan/runbook fanned out across a resolved
    target set (services.targets). Groups the per-host child runs it spawned
    (PlanRun / RunbookRun ids in `results`) into a single trackable unit."""

    __tablename__ = "deployment_runs"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    tenant_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False, default=DEFAULT_TENANT_ID)
    kind: Mapped[str] = mapped_column(String, nullable=False)  # plan | stored_plan | runbook
    target_ref: Mapped[str] = mapped_column(String, nullable=False)  # plan/runbook name (prefix/name for stored)
    dry_run: Mapped[bool] = mapped_column(nullable=False, default=False)
    status: Mapped[str] = mapped_column(String, nullable=False, default="running")
    total_hosts: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    ok_hosts: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    failed_hosts: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    unknown_hostnames: Mapped[list[str]] = mapped_column(ARRAY(String), nullable=False, default=list)
    # [{agent_id, agent_name, run_id, run_kind, status, changed, error}]
    results: Mapped[list] = mapped_column(JSONB, nullable=False, default=list)
    requested_by: Mapped[str | None] = mapped_column(String)
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)

    __table_args__ = (
        CheckConstraint("status IN ('running', 'ok', 'partial', 'failed')", name="ck_deployment_runs_status"),
        CheckConstraint("kind IN ('plan', 'stored_plan', 'runbook')", name="ck_deployment_runs_kind"),
    )


class PlanRunStep(Base):
    """One step's result within a plan run."""

    __tablename__ = "plan_run_steps"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    plan_run_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("plan_runs.id", ondelete="CASCADE"), nullable=False
    )
    step_index: Mapped[int] = mapped_column(Integer, nullable=False)
    step_name: Mapped[str] = mapped_column(String, nullable=False)
    module: Mapped[str | None] = mapped_column(String)
    request_body: Mapped[dict] = mapped_column(JSONB, nullable=False)
    response_body: Mapped[dict | None] = mapped_column(JSONB)
    changed: Mapped[bool | None] = mapped_column()
    http_status: Mapped[int | None] = mapped_column(Integer)
    error: Mapped[str | None] = mapped_column(String)
    started_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)
    finished_at: Mapped[datetime | None] = mapped_column(TZ_DATETIME)

    plan_run: Mapped["PlanRun"] = relationship(back_populates="steps")

    __table_args__ = (Index("idx_plan_run_steps_run", "plan_run_id", "step_index"),)


class PlanDocument(Base):
    """The canonical, prefix-keyed plan document store (docs/zielbestimmung.md
    principle 4): ONE table holding every deployment plan as its canonical
    JSON `body` — the (coerced) raw dict that plan_loader.build_plan_from_raw
    consumes, i.e. "all formats converted to JSON". Keyed by `prefix` (the
    origin system: ansible/salt/puppet/chef), `name`, and an immutable
    `version` (mirroring OrchestrationPlanVersion's versioning). `source_text`
    keeps the original for re-parse/diff; `source_format` records how it was
    authored/imported (nestedtext/yaml/json/salt/puppet/chef). Content-
    addressed like the translation caches (ChunkEmbedding.source_hash/chunk_id):
    `source_hash` over the source text, `content_hash` over the canonical body
    (== Plan.version()) so an unchanged re-store is a no-op."""

    __tablename__ = "plans"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    tenant_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False,
        server_default=text(f"'{DEFAULT_TENANT_ID}'"),
    )
    prefix: Mapped[str] = mapped_column(String, nullable=False)
    name: Mapped[str] = mapped_column(String, nullable=False)
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    source_format: Mapped[str] = mapped_column(String, nullable=False)
    source_text: Mapped[str] = mapped_column(Text, nullable=False)
    body: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)
    source_hash: Mapped[str] = mapped_column(String, nullable=False)
    content_hash: Mapped[str] = mapped_column(String, nullable=False)
    created_by: Mapped[str | None] = mapped_column(String)
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)

    __table_args__ = (
        UniqueConstraint("tenant_id", "prefix", "name", "version", name="uq_plans_tenant_prefix_name_version"),
        CheckConstraint(
            "prefix IN ('ansible', 'salt', 'puppet', 'chef')",
            name="ck_plans_prefix",
        ),
        Index("idx_plans_lookup", "tenant_id", "prefix", "name", "version"),
    )


class PlanPlacement(Base):
    """Where a logical plan/role (prefix+name, across all its versions) sits in
    the plan-library directory tree. One row per logical plan (not per version).
    `folder` is the human path ("linux/base"); `ltree_path` is the sanitized
    ltree for subtree queries (mirrors OUNode.path/ltree_path). Un-placed plans
    are treated as living at the root."""

    __tablename__ = "plan_placements"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    tenant_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False,
        server_default=text(f"'{DEFAULT_TENANT_ID}'"),
    )
    prefix: Mapped[str] = mapped_column(String, nullable=False)
    name: Mapped[str] = mapped_column(String, nullable=False)
    folder: Mapped[str] = mapped_column(String, nullable=False, default="")
    ltree_path: Mapped[str] = mapped_column(LTREE, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)

    __table_args__ = (
        UniqueConstraint("tenant_id", "prefix", "name", name="uq_plan_placements_plan"),
        Index("idx_plan_placements_lookup", "tenant_id", "prefix", "name"),
    )


class Metric(Base):
    """A metrics-dump data point pulled from an agent — a TimescaleDB
    hypertable (see the Alembic migration), the direct RRD replacement."""

    __tablename__ = "metrics"

    time: Mapped[datetime] = mapped_column(TZ_DATETIME, nullable=False, primary_key=True)
    agent_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("agents.id"), nullable=False, primary_key=True
    )
    metric: Mapped[str] = mapped_column(String, nullable=False, primary_key=True)
    value: Mapped[float] = mapped_column(nullable=False)
    labels: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)

    __table_args__ = (Index("idx_metrics_agent_metric_time", "agent_id", "metric", "time"),)


class BossmanUser(Base):
    """A human operator account for the Bossman dashboard (JWT login)."""

    __tablename__ = "bossman_users"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    username: Mapped[str] = mapped_column(String, unique=True, nullable=False)
    password_hash: Mapped[str] = mapped_column(String, nullable=False)
    role: Mapped[str] = mapped_column(String, nullable=False, default="operator")
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)

    __table_args__ = (CheckConstraint("role IN ('admin', 'operator')", name="ck_bossman_users_role"),)


class ApiToken(Base):
    """A machine/AI bearer token for the MCP facade — deliberately separate
    from BossmanUser, since machine callers and human operators are
    different principals with different lifecycles (see docs/plan.md's
    dual-auth decision)."""

    __tablename__ = "api_tokens"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    name: Mapped[str] = mapped_column(String, nullable=False)
    token_hash: Mapped[str] = mapped_column(String, unique=True, nullable=False)
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)
    revoked_at: Mapped[datetime | None] = mapped_column(TZ_DATETIME)


class AccessGrant(Base):
    """Block M — a per-subject host-management access grant. Enforcement:
    admin users bypass entirely; every other user AND every api_token may only
    manage hosts they hold a grant for. scope='all' is a wildcard (keeps
    admin-issued automation tokens working); 'host' targets one agent;
    'host_group' targets a HostGroup, expanded to its members at check time."""

    __tablename__ = "access_grants"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    subject_kind: Mapped[str] = mapped_column(String, nullable=False)  # user | api_token
    subject_ref: Mapped[str] = mapped_column(String, nullable=False)  # username or token name
    scope: Mapped[str] = mapped_column(String, nullable=False)  # all | host | host_group
    agent_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), ForeignKey("agents.id", ondelete="CASCADE"))
    host_group_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("host_groups.id", ondelete="CASCADE")
    )
    permission: Mapped[str] = mapped_column(String, nullable=False, default="manage")
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)

    __table_args__ = (
        CheckConstraint("subject_kind IN ('user', 'api_token')", name="ck_access_grants_subject_kind"),
        CheckConstraint("scope IN ('all', 'host', 'host_group')", name="ck_access_grants_scope"),
        Index("idx_access_grants_subject", "subject_kind", "subject_ref"),
    )


class HostCve(Base):
    """Block 4-C — one CVE that a pending package upgrade on a host would fix,
    produced by correlating the host's package_updates against the cached CVE
    feed (Debian/Ubuntu trackers) or the agent's own dnf updateinfo (RHEL).
    Replace-on-collect per agent: a collection wipes the agent's rows and
    re-inserts, so the table always reflects the latest snapshot."""

    __tablename__ = "host_cves"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    agent_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("agents.id", ondelete="CASCADE"), nullable=False)
    cve: Mapped[str] = mapped_column(String, nullable=False)
    package: Mapped[str] = mapped_column(String, nullable=False)  # binary package
    source_package: Mapped[str] = mapped_column(String, nullable=False, default="")
    current_version: Mapped[str] = mapped_column(String, nullable=False, default="")
    fixed_version: Mapped[str] = mapped_column(String, nullable=False, default="")
    severity: Mapped[str] = mapped_column(String, nullable=False, default="")
    distro: Mapped[str] = mapped_column(String, nullable=False, default="")
    collected_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)

    __table_args__ = (
        Index("idx_host_cves_agent", "agent_id"),
        Index("idx_host_cves_cve", "cve"),
        Index("idx_host_cves_severity", "severity"),
    )


class ChunkEmbedding(Base):
    """One translated plan chunk's foreign source text, embedded — the
    fuzzy, additive layer on top of plan_loader's exact chunk_id/
    source_hash comparison (see services/chunk_similarity.py and
    docs/plan.md's "Chunk-similarity embedding cache"). `chunk_id` is the
    natural primary key: it's already content-addressed (a sha256 of the
    chunk's normalized steps), so one row per distinct translated chunk
    content, regardless of which plan/file first produced it."""

    __tablename__ = "chunk_embeddings"

    chunk_id: Mapped[str] = mapped_column(String, primary_key=True)
    plan_name: Mapped[str] = mapped_column(String, nullable=False)
    chunk_name: Mapped[str] = mapped_column(String, nullable=False)
    source_hash: Mapped[str | None] = mapped_column(String)
    source_text: Mapped[str] = mapped_column(Text, nullable=False)
    embedding: Mapped[list[float]] = mapped_column(Vector(CHUNK_EMBEDDING_DIM), nullable=False)
    # Which embedding model produced `embedding` — a model switch
    # invalidates old rows (their vectors live in an incomparable space),
    # so callers filter/re-index by this rather than assuming every row is
    # current.
    model: Mapped[str] = mapped_column(String, nullable=False)
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)
    # The actual translated Bossman chunk content (JSON: {"os_family":
    # [...] | null, "steps": [...]}), set by services/translator.py after a
    # real LLM translation succeeds — makes this row self-sufficient for
    # reuse (services/translator.py's "reused" path reconstructs a Chunk
    # straight from this column, no dependency on the plan file that
    # originally produced it still existing/being loaded). NULL for rows
    # indexed the older way (source text registered for fuzzy matching
    # only, e.g. by a human referencing an already-committed plan file) —
    # those rows still match on similarity, they just can't offer a direct
    # reuse reconstruction.
    translated_json: Mapped[str | None] = mapped_column(Text)


class PlanEmbedding(Base):
    """One plan's name+description, embedded — backs search_plans (see
    services/plan_search.py and docs/plan.md's "Plan-catalog RAG"): finding
    the few relevant plans for a natural-language request without dumping
    every plan's description into the (cached) system prompt, which stops
    scaling once the catalog grows past a handful of plans. `name` is the
    natural primary key — SQLAlchemy load_plans_dir already enforces plan
    names are unique across the whole plans_dir."""

    __tablename__ = "plan_embeddings"

    name: Mapped[str] = mapped_column(String, primary_key=True)
    description: Mapped[str] = mapped_column(Text, nullable=False)
    # sha256 of the exact text that was embedded (name + description) —
    # the short-circuit key for index_plan_catalog's "only re-embed what
    # changed" batch upsert, the same content-addressing idea as
    # ChunkEmbedding.source_hash/chunk_id.
    content_hash: Mapped[str] = mapped_column(String, nullable=False)
    embedding: Mapped[list[float]] = mapped_column(Vector(CHUNK_EMBEDDING_DIM), nullable=False)
    model: Mapped[str] = mapped_column(String, nullable=False)
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)


class SeverityLabel(Base):
    """Display-only label/color override per state (Zabbix gap-analysis
    Block K10) — cosmetic: `state` stays yolo-man's real 4-value state
    machine (OK/WARN/CRIT/UNKNOWN), `label`/`color` are just how the UI
    shows it. One seeded row per state (see the migration's defaults),
    never created/deleted via the API, only updated."""

    __tablename__ = "severity_labels"

    state: Mapped[str] = mapped_column(String, primary_key=True)
    label: Mapped[str] = mapped_column(String, nullable=False)
    color: Mapped[str] = mapped_column(String, nullable=False)

    __table_args__ = (CheckConstraint("state IN ('OK', 'WARN', 'CRIT', 'UNKNOWN')", name="ck_severity_labels_state"),)


class Graph(Base):
    """A saved, reusable chart combining items from several hosts on one
    chart (Zabbix gap-analysis Block K11) — unlike a dashboard widget's
    ad-hoc series, this is a named, editable object with its own draw
    options, made of GraphItem rows."""

    __tablename__ = "graphs"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    name: Mapped[str] = mapped_column(String, nullable=False, unique=True)
    graph_type: Mapped[str] = mapped_column(String, nullable=False, default="normal")
    y_axis_mode: Mapped[str] = mapped_column(String, nullable=False, default="calculated")
    show_legend: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    show_working_time: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)

    items: Mapped[list["GraphItem"]] = relationship(
        back_populates="graph", cascade="all, delete-orphan", order_by="GraphItem.sort_order"
    )

    __table_args__ = (CheckConstraint("graph_type IN ('normal', 'stacked')", name="ck_graphs_graph_type"),)


class GraphItem(Base):
    """One member series of a Graph — pinned to one agent+metric with its
    own display options (Block K11)."""

    __tablename__ = "graph_items"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    graph_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("graphs.id", ondelete="CASCADE"), nullable=False)
    agent_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("agents.id", ondelete="CASCADE"), nullable=False)
    metric: Mapped[str] = mapped_column(String, nullable=False)
    label: Mapped[str | None] = mapped_column(String)
    color: Mapped[str] = mapped_column(String, nullable=False, default="#1e9600")
    draw_style: Mapped[str] = mapped_column(String, nullable=False, default="line")
    axis_side: Mapped[str] = mapped_column(String, nullable=False, default="left")
    function: Mapped[str] = mapped_column(String, nullable=False, default="avg")
    sort_order: Mapped[int] = mapped_column(Integer, nullable=False, default=0)

    graph: Mapped["Graph"] = relationship(back_populates="items")

    __table_args__ = (
        CheckConstraint(
            "draw_style IN ('line', 'bold_line', 'filled', 'dot', 'dashed', 'gradient')",
            name="ck_graph_items_draw_style",
        ),
        CheckConstraint("axis_side IN ('left', 'right')", name="ck_graph_items_axis_side"),
        CheckConstraint("function IN ('avg', 'min', 'max', 'last')", name="ck_graph_items_function"),
    )


class TemplateGroup(Base):
    """Organizational container for Templates (Zabbix gap-analysis Block
    K12), the same role HostGroup-style tags play for agents."""

    __tablename__ = "template_groups"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    name: Mapped[str] = mapped_column(String, nullable=False, unique=True)


class Template(Base):
    """A named, reusable bundle of check rules (Block K12) — the biggest
    single gap the Zabbix comparison found. Live-linked (not copied) to
    one or more host groups via TemplateLink: editing a Template's rules
    or its nesting and re-materializing regenerates every linked group's
    CheckRule rows to match. Nestable via TemplateNesting (a template can
    include other templates' rules). Scoped to check-rule bundling for
    v1 — see the migration's docstring for what's deferred."""

    __tablename__ = "templates"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    name: Mapped[str] = mapped_column(String, nullable=False, unique=True)
    description: Mapped[str] = mapped_column(String, nullable=False, default="")
    template_group_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("template_groups.id", ondelete="SET NULL")
    )
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)

    rules: Mapped[list["TemplateRule"]] = relationship(back_populates="template", cascade="all, delete-orphan")


class TemplateRule(Base):
    """One bundled check definition within a Template (Block K12) — the
    same shape as CheckRule minus scope (scope comes from the TemplateLink
    a Template is linked with, not the rule itself)."""

    __tablename__ = "template_rules"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    template_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("templates.id", ondelete="CASCADE"), nullable=False)
    service_name: Mapped[str] = mapped_column(String, nullable=False)
    metric: Mapped[str] = mapped_column(String, nullable=False)
    comparison: Mapped[str] = mapped_column(String, nullable=False)
    warn_threshold: Mapped[float | None] = mapped_column(Float)
    crit_threshold: Mapped[float | None] = mapped_column(Float)
    label_value: Mapped[str | None] = mapped_column(String)
    max_attempts: Mapped[int | None] = mapped_column(Integer)
    recovery_threshold: Mapped[float | None] = mapped_column(Float)
    value_map_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), ForeignKey("value_maps.id", ondelete="SET NULL"))
    depends_on_service_name: Mapped[str | None] = mapped_column(String)
    extra_conditions: Mapped[list | None] = mapped_column(JSONB)
    condition_logic: Mapped[str] = mapped_column(String, nullable=False, default="AND")

    template: Mapped["Template"] = relationship(back_populates="rules")

    __table_args__ = (
        CheckConstraint("comparison IN ('gt', 'lt', 'ge', 'le', 'eq', 'ne')", name="ck_template_rules_comparison"),
        CheckConstraint("condition_logic IN ('AND', 'OR')", name="ck_template_rules_condition_logic"),
    )


class TemplateNesting(Base):
    """parent template includes child template's rules (Block K12) — a
    plain association row, queried directly (both directions) by
    services/templates.py's materialization walk rather than through an
    ORM relationship, since that walk needs both parent->children and
    child->parents traversal."""

    __tablename__ = "template_nesting"

    parent_template_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("templates.id", ondelete="CASCADE"), primary_key=True)
    child_template_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("templates.id", ondelete="CASCADE"), primary_key=True)

    __table_args__ = (CheckConstraint("parent_template_id != child_template_id", name="ck_template_nesting_no_self_nest"),)


class TemplateLink(Base):
    """A Template linked to one host group (Block K12) — the "live" part
    of "live-linked": services/templates.py's materialize_template_link
    keeps this group's CheckRule rows in sync with the template's current
    effective rule set (own + nested) whenever the template, its nesting,
    or this link changes."""

    __tablename__ = "template_links"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    template_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("templates.id", ondelete="CASCADE"), nullable=False)
    host_group: Mapped[str] = mapped_column(String, nullable=False)

    __table_args__ = (UniqueConstraint("template_id", "host_group", name="uq_template_links_template_group"),)


class ValueMap(Base):
    """A reusable named numeric/string -> human-label mapping (Zabbix gap-
    analysis Block K4), e.g. {"0": "Down", "1": "Up"}. Attached to a
    CheckRule via CheckRule.value_map_id; a Service materialized from that
    rule shows the mapped label alongside its raw value (see
    services/monitoring.py's ServiceView.mapped_value)."""

    __tablename__ = "value_maps"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    name: Mapped[str] = mapped_column(String, nullable=False, unique=True)
    mappings: Mapped[dict] = mapped_column(JSONB, nullable=False)
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)


# --------------------------------------------------------------------------
# Policy & Orchestration layer (Block L1) — the OU tree, first-class host
# groups, versioned orchestration plans, and the per-host compiled desired
# state. All additive; see the approved L-series plan and the
# b3f1a2c9d740 migration. Every service that walks these tables uses
# explicit select() queries (not lazy relationship traversal) to avoid the
# MissingGreenlet class of bug found in Block K11.
# --------------------------------------------------------------------------


class Tenant(Base):
    """A tenant — multi-tenancy from day one (Block L1). Every OU node,
    host group, orchestration plan and compiled state is scoped to one.
    The L1 migration seeds a fixed 'default' tenant and backfills every
    existing agent onto it."""

    __tablename__ = "tenants"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    name: Mapped[str] = mapped_column(String, nullable=False)
    slug: Mapped[str] = mapped_column(String, nullable=False, unique=True)
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)


class OUNode(Base):
    """One node in the OU tree (Block L1) — AD-style: a host lives at
    exactly one OU (agents.ou_id), and inheritance flows down the tree. A
    rule/plan linked to this OU applies to every host in its subtree.
    `path` is the materialized slash-path (e.g. /Germany/Munich/Prod),
    unique per tenant, matching the slash convention agents.groups already
    uses. parent_id NULL means a tenant root."""

    __tablename__ = "ou_nodes"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    tenant_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False)
    parent_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), ForeignKey("ou_nodes.id", ondelete="CASCADE"))
    name: Mapped[str] = mapped_column(String, nullable=False)
    path: Mapped[str] = mapped_column(String, nullable=False)
    # Block L3a: the materialized ltree label-path (sanitized from `path` —
    # slashes become dots, chars outside [A-Za-z0-9_-] become _). GiST-indexed
    # for ancestor/descendant queries. `path` stays the human-readable form
    # (may contain spaces the ltree segment can't).
    ltree_path: Mapped[str] = mapped_column(LTREE, nullable=False)
    # Block L3a: GPO "Block Inheritance" — when true, non-enforced rules
    # inherited from levels above this OU are dropped (enforced still apply).
    block_inheritance: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)
    deleted_at: Mapped[datetime | None] = mapped_column(TZ_DATETIME)

    __table_args__ = (UniqueConstraint("tenant_id", "path", name="uq_ou_nodes_tenant_path"),)


class HostGroup(Base):
    """A first-class host group (Block L1) — the AD "group" object: it
    lives inside an OU (ou_id) but has many-to-many host membership via
    HostGroupMember, which is how a host gets assignments beyond its single
    OU placement. Distinct from the legacy flat agents.groups string list,
    which stays untouched in L1."""

    __tablename__ = "host_groups"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    tenant_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False)
    ou_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), ForeignKey("ou_nodes.id", ondelete="SET NULL"))
    name: Mapped[str] = mapped_column(String, nullable=False)
    description: Mapped[str] = mapped_column(String, nullable=False, default="")
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)
    deleted_at: Mapped[datetime | None] = mapped_column(TZ_DATETIME)

    __table_args__ = (UniqueConstraint("tenant_id", "name", name="uq_host_groups_tenant_name"),)


class HostGroupMember(Base):
    """A host's membership in a HostGroup (Block L1) — the many-to-many
    join implementing the AD model's cross-cutting group membership."""

    __tablename__ = "host_group_members"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    tenant_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False)
    host_group_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("host_groups.id", ondelete="CASCADE"), nullable=False)
    agent_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("agents.id", ondelete="CASCADE"), nullable=False)

    __table_args__ = (UniqueConstraint("host_group_id", "agent_id", name="uq_host_group_members_group_agent"),)


class OrchestrationPlan(Base):
    """A named, reusable orchestration plan (Block L1) — a role like
    docker_host, a cluster like postgres_cluster, a deployment, etc. The
    plan itself is a stable named handle; its actual content lives in
    versioned OrchestrationPlanVersion rows (current_version points at the
    live one). Linked to scopes via OrchestrationPlanLink."""

    __tablename__ = "orchestration_plans"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    tenant_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False)
    name: Mapped[str] = mapped_column(String, nullable=False)
    display_name: Mapped[str] = mapped_column(String, nullable=False)
    description: Mapped[str] = mapped_column(String, nullable=False, default="")
    plan_type: Mapped[str] = mapped_column(String, nullable=False)
    enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    current_version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    created_by: Mapped[str | None] = mapped_column(String)
    updated_by: Mapped[str | None] = mapped_column(String)
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)
    deleted_at: Mapped[datetime | None] = mapped_column(TZ_DATETIME)

    __table_args__ = (
        UniqueConstraint("tenant_id", "name", name="uq_orchestration_plans_tenant_name"),
        CheckConstraint(
            "plan_type IN ('role', 'cluster', 'deployment', 'remediation', 'maintenance', 'bootstrap')",
            name="ck_orchestration_plans_plan_type",
        ),
    )


class OrchestrationPlanVersion(Base):
    """One immutable version of an OrchestrationPlan (Block L1). Holds the
    parameter schema/defaults, requirements, steps (idempotent
    package/file/service/command actions run by the existing plan engine +
    Go modules), rollback/validation steps, and — crucially — the monitoring
    and notifications this role generates automatically (proposal §12: "was
    orchestriert wird, wird überwacht"). The compiler reads generated_*."""

    __tablename__ = "orchestration_plan_versions"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    tenant_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False)
    plan_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("orchestration_plans.id", ondelete="CASCADE"), nullable=False)
    version: Mapped[int] = mapped_column(Integer, nullable=False)
    parameter_schema: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)
    default_parameters: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)
    requirements: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)
    steps: Mapped[list] = mapped_column(JSONB, nullable=False, default=list)
    rollback_steps: Mapped[list] = mapped_column(JSONB, nullable=False, default=list)
    validation_steps: Mapped[list] = mapped_column(JSONB, nullable=False, default=list)
    generated_monitoring: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)
    generated_notifications: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)
    created_by: Mapped[str | None] = mapped_column(String)
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)

    __table_args__ = (
        UniqueConstraint("tenant_id", "plan_id", "version", name="uq_orchestration_plan_versions_plan_version"),
    )


class OrchestrationPlanLink(Base):
    """A plan linked to a scope (Block L1, proposal §9) — target_type says
    which of ou_id/agent_id/host_group_id is set (or global/label_selector).
    plan_version NULL = follow the plan's current_version. The compiler
    collects every link that reaches a host (global + each OU on its
    ancestry path + each group it's in + host-direct), applies priority/
    link_order, and merges parameters over the version's defaults."""

    __tablename__ = "orchestration_plan_links"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    tenant_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False)
    plan_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("orchestration_plans.id", ondelete="CASCADE"), nullable=False)
    plan_version: Mapped[int | None] = mapped_column(Integer)
    target_type: Mapped[str] = mapped_column(String, nullable=False)
    ou_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), ForeignKey("ou_nodes.id", ondelete="CASCADE"))
    agent_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), ForeignKey("agents.id", ondelete="CASCADE"))
    host_group_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), ForeignKey("host_groups.id", ondelete="CASCADE"))
    conditions: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)
    parameters: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)
    priority: Mapped[int] = mapped_column(Integer, nullable=False, default=100)
    link_order: Mapped[int] = mapped_column(Integer, nullable=False, default=100)
    enforced: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    auto_apply: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    require_approval: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    # Block L2: pending_approval (safe default) until a human approves it —
    # only 'active' links are picked up by
    # compiler.resolve_orchestration_assignments. Set at creation time by
    # api/orchestration.py's create_plan_link based on require_approval/
    # auto_apply and the global SystemSettings.yolo_mode override; never
    # settable directly by the MCP write tool (see mcp/server.py).
    status: Mapped[str] = mapped_column(String, nullable=False, default="pending_approval")
    created_by: Mapped[str | None] = mapped_column(String)
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)

    __table_args__ = (
        CheckConstraint(
            "target_type IN ('ou', 'host', 'group', 'label_selector', 'global')",
            name="ck_orchestration_plan_links_target_type",
        ),
        CheckConstraint(
            "status IN ('pending_approval', 'active', 'rejected')", name="ck_orchestration_plan_links_status"
        ),
    )


class CheckAssignment(Base):
    """Assigns a check (checks.d/<check_name>) to a scope — a host, a host
    group, or an OU — with per-scope parameters/thresholds (Block G9-P2). A
    host's effective checks are resolved GPO-style: every assignment that
    reaches it (host-direct + each group it belongs to + each OU on its
    ancestry path), deduped per check_name with host > group > OU precedence,
    parameters merged (inherited < more specific). Mirrors
    OrchestrationPlanLink's scope columns; source records where an
    auto-discovery run created it."""

    __tablename__ = "check_assignments"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    tenant_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False)
    check_name: Mapped[str] = mapped_column(String, nullable=False)
    scope_type: Mapped[str] = mapped_column(String, nullable=False)  # ou | group | host
    ou_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), ForeignKey("ou_nodes.id", ondelete="CASCADE"))
    agent_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), ForeignKey("agents.id", ondelete="CASCADE"))
    host_group_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), ForeignKey("host_groups.id", ondelete="CASCADE"))
    parameters: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)
    enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    source: Mapped[str] = mapped_column(String, nullable=False, default="manual")  # manual | autodiscovered | ai
    created_by: Mapped[str | None] = mapped_column(String)
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)

    __table_args__ = (
        CheckConstraint("scope_type IN ('ou', 'group', 'host')", name="ck_check_assignments_scope_type"),
        Index("idx_check_assignments_agent", "agent_id"),
        Index("idx_check_assignments_group", "host_group_id"),
        Index("idx_check_assignments_ou", "ou_id"),
        Index("idx_check_assignments_check", "check_name"),
    )


class Runbook(Base):
    """A NestedText runbook/role stored as its canonical JSON document
    (Block G11). Runbooks live in the DB (unlike modules/checks, which stay on
    the filesystem); NestedText is the authoring/display form, converted to/
    from `doc` by services/nt_convert. `kind` mirrors doc['kind']
    (runbook|role) for cheap listing/filtering."""

    __tablename__ = "runbooks"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    tenant_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False)
    name: Mapped[str] = mapped_column(String, nullable=False)
    kind: Mapped[str] = mapped_column(String, nullable=False, default="runbook")  # runbook | role
    # Folder path for the library tree (e.g. "linux/base"); "" = root. Mirrors
    # the plan-library's folder organization so the runbook editor can show the
    # same directory tree.
    folder: Mapped[str] = mapped_column(String, nullable=False, default="")
    doc: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)
    created_by: Mapped[str | None] = mapped_column(String)
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), onupdate=func.now(), nullable=False)

    __table_args__ = (
        UniqueConstraint("tenant_id", "name", name="uq_runbooks_tenant_name"),
        CheckConstraint("kind IN ('runbook', 'role')", name="ck_runbooks_kind"),
    )


class ScopeVars(Base):
    """Variables attached to a scope — a host, a host group, or an OU (Block
    G11). A runbook/role run resolves them GPO-style (global < group < OU
    root→leaf < host), the same precedence as check thresholds, so a value set
    on an OU is inherited by its hosts and overridable per group/host. `vars`
    is a flat JSONB dict of name → value."""

    __tablename__ = "scope_vars"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    tenant_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False)
    scope_type: Mapped[str] = mapped_column(String, nullable=False)  # ou | group | host
    ou_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), ForeignKey("ou_nodes.id", ondelete="CASCADE"))
    agent_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), ForeignKey("agents.id", ondelete="CASCADE"))
    host_group_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), ForeignKey("host_groups.id", ondelete="CASCADE"))
    vars: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), onupdate=func.now(), nullable=False)

    __table_args__ = (
        CheckConstraint("scope_type IN ('ou', 'group', 'host')", name="ck_scope_vars_scope_type"),
        Index("idx_scope_vars_ou", "ou_id"),
        Index("idx_scope_vars_group", "host_group_id"),
        Index("idx_scope_vars_agent", "agent_id"),
    )


class RunbookRun(Base):
    """One execution of a runbook against a host (Block G11) — the audit
    trail, like PlanRun for plans. `result` is the engine's RunResult
    (per-step ok/changed/skipped/failed). dry_run=true is a check_mode
    preview. Kept as a JSONB blob rather than per-step rows: a runbook run is
    reviewed as a whole, and the doc is already DB-canonical."""

    __tablename__ = "runbook_runs"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    tenant_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False)
    runbook_name: Mapped[str] = mapped_column(String, nullable=False)
    agent_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), ForeignKey("agents.id", ondelete="SET NULL"))
    dry_run: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    status: Mapped[str] = mapped_column(String, nullable=False, default="ok")  # ok | failed | aborted
    changed: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    result: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)
    requested_by: Mapped[str | None] = mapped_column(String)
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)

    __table_args__ = (Index("idx_runbook_runs_agent", "agent_id"),)


class SystemSettings(Base):
    """One-and-only row of Bossman-wide runtime toggles (Block L2) — DB-
    backed (not env-var) so they flip instantly via the REST API/UI without
    a process restart, the same way Claude Code's own auto/manual mode
    toggles instantly mid-session.

    `yolo_mode` (named for the project itself — "You Only Look Once") is
    the global override for the Policy/Orchestration approval gate: when
    true, every new OrchestrationPlanLink is created `active` immediately,
    bypassing its own require_approval/auto_apply values entirely. Off
    (the seeded default) is the safe, per-link-gated posture. Deliberately
    human-only: the MCP write tool never sets this, only the REST endpoint
    a real logged-in caller hits (see api/system_settings.py)."""

    __tablename__ = "system_settings"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    yolo_mode: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    updated_by: Mapped[str | None] = mapped_column(String)
    updated_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)


class CompiledHostState(Base):
    """The per-host compiled desired state (Block L1) — the compiler's
    output: the full desired-state document (monitoring{} + orchestration{})
    with a monotonic `generation` and a sha256 `config_hash` of its
    canonical JSON. A new generation is written only when the hash changes;
    at most one row per host has is_current=true (partial unique index).
    L1 stores it for inspection; the push controller (L3) consumes it."""

    __tablename__ = "compiled_host_state"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    tenant_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False)
    agent_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("agents.id", ondelete="CASCADE"), nullable=False)
    generation: Mapped[int] = mapped_column(BigInteger, nullable=False)
    config_hash: Mapped[str] = mapped_column(String, nullable=False)
    state: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)
    explain: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)
    is_current: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    compiled_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)

    __table_args__ = (
        UniqueConstraint("tenant_id", "agent_id", "generation", name="uq_compiled_host_state_agent_generation"),
    )


class PolicyEvent(Base):
    """A change signal (Block L4) — a rule/OU/link/label/plan change writes
    one of these in the SAME transaction as the change (transactional
    outbox), so the reconciler never misses a change. Holds only the ids of
    what changed, never the compiled config itself."""

    __tablename__ = "policy_events"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    tenant_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False)
    kind: Mapped[str] = mapped_column(String, nullable=False)
    payload: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)

    __table_args__ = (
        CheckConstraint(
            "kind IN ('rule_changed', 'ou_changed', 'host_moved', 'label_changed', 'plan_changed', 'link_changed')",
            name="ck_policy_events_kind",
        ),
    )


class ControllerOutbox(Base):
    """A retryable work item (Block L4) — the reconciler consumes these with
    FOR UPDATE SKIP LOCKED, recompiles the affected hosts, enqueues
    deliveries, and marks the row done. Failures back off via available_at."""

    __tablename__ = "controller_outbox"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    tenant_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False)
    event_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("policy_events.id", ondelete="CASCADE"), nullable=False)
    status: Mapped[str] = mapped_column(String, nullable=False, default="pending")
    attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    last_error: Mapped[str | None] = mapped_column(Text)
    available_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)
    processed_at: Mapped[datetime | None] = mapped_column(TZ_DATETIME)
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)

    __table_args__ = (
        CheckConstraint("status IN ('pending', 'processing', 'done', 'failed')", name="ck_controller_outbox_status"),
    )


class AgentConfigDelivery(Base):
    """One delivery of a compiled generation to an agent (Block L4) — idempotent
    on (agent_id, generation). Status tracks pull/ack lifecycle; the agent
    never has more than one row per generation."""

    __tablename__ = "agent_config_delivery"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    tenant_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False)
    agent_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("agents.id", ondelete="CASCADE"), nullable=False)
    generation: Mapped[int] = mapped_column(BigInteger, nullable=False)
    config_hash: Mapped[str] = mapped_column(String, nullable=False)
    status: Mapped[str] = mapped_column(String, nullable=False, default="pending")
    attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    last_error: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)

    __table_args__ = (
        UniqueConstraint("agent_id", "generation", name="uq_agent_config_delivery_agent_generation"),
        CheckConstraint(
            "status IN ('pending', 'sent', 'acked', 'nacked', 'failed')", name="ck_agent_config_delivery_status"
        ),
    )


class AgentAck(Base):
    """An agent's ack/nack of a delivered generation (Block L4)."""

    __tablename__ = "agent_acks"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    tenant_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False)
    agent_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("agents.id", ondelete="CASCADE"), nullable=False)
    generation: Mapped[int] = mapped_column(BigInteger, nullable=False)
    result: Mapped[str] = mapped_column(String, nullable=False)
    detail: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)

    __table_args__ = (CheckConstraint("result IN ('ack', 'nack')", name="ck_agent_acks_result"),)


class CheckRule(Base):
    """A CheckMK-style monitoring rule: "if <metric> <comparison> <warn/
    crit threshold>, that's a WARN/CRIT service named <service_name>" (see
    services/monitoring.py and docs/plan.md's monitoring Block E2). Scoped
    to `global` (every host), a `group` (agents.groups membership), or one
    specific `host` (agents.name) — resolve_effective_rule applies the
    most specific match (host > group > global), the same precedence
    CheckMK's own rule-set editor uses, per the user's explicit request
    ("Regeln für Gruppen ... die von Host-Regeln übersteuert werden
    können")."""

    __tablename__ = "check_rules"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    service_name: Mapped[str] = mapped_column(String, nullable=False)
    metric: Mapped[str] = mapped_column(String, nullable=False)
    comparison: Mapped[str] = mapped_column(String, nullable=False)
    warn_threshold: Mapped[float | None] = mapped_column(Float)
    crit_threshold: Mapped[float | None] = mapped_column(Float)
    scope_type: Mapped[str] = mapped_column(String, nullable=False, default="global")
    # NULL for scope_type=global; a group name for scope_type=group; an
    # agent name for scope_type=host.
    scope_value: Mapped[str | None] = mapped_column(String)
    # An optional single label value the rule is pinned to — for labeled
    # metrics like disk_used_pct (one series per mount): NULL applies to
    # every series (the default, fanning out to one service per mount),
    # a value like "/var" overrides just that mount (Block H6). The label
    # key is implicit per metric (mount for disk); modelling one value is
    # enough for the only labeled check dimension the built-ins use.
    label_value: Mapped[str | None] = mapped_column(String)
    # Consecutive non-OK checks before the state goes hard (Block H7);
    # NULL = the global default (DEFAULT_MAX_ATTEMPTS in services/monitoring).
    max_attempts: Mapped[int | None] = mapped_column(Integer)
    enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    # A default rule reproduces a former hardcoded agent threshold (Block
    # H6 seeding) — surfaced so the UI can mark it and re-seeding can skip
    # user-created rules.
    is_default: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)
    # Block K4: an optional reusable numeric/string -> label mapping,
    # shown alongside a materialized Service's raw value. SET NULL on
    # delete — removing a value map shouldn't take the rule down with it.
    value_map_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), ForeignKey("value_maps.id", ondelete="SET NULL"))
    # Block K6: an optional stricter threshold a problem must cross before
    # recovering to OK — a deadband/hysteresis, Zabbix's "recovery
    # expression". NULL = recover as soon as the value clears warn_threshold
    # (today's behavior).
    recovery_threshold: Mapped[float | None] = mapped_column(Float)
    # Block K8: name of another service (same agent) this one depends on —
    # a symptom whose notification is suppressed while its root-cause
    # service is already a confirmed (hard) problem. Name-based, same-host
    # only (not a full cross-host dependency graph).
    depends_on_service_name: Mapped[str | None] = mapped_column(String)
    # Block K9: a scoped v1 of Zabbix's multi-item boolean trigger
    # expressions — other metrics (same host, unlabeled/whole-host only),
    # each {"metric", "comparison", "warn_threshold", "crit_threshold"},
    # combined with the primary condition via condition_logic. NULL/empty
    # = today's single-metric behavior.
    extra_conditions: Mapped[list | None] = mapped_column(JSONB)
    condition_logic: Mapped[str] = mapped_column(String, nullable=False, default="AND")
    # Block K12: set only on a CheckRule materialized FROM a Template's
    # TemplateLink — template_id says which template owns it (CASCADE:
    # deleting the template removes every rule it generated);
    # source_template_rule_id is the exact TemplateRule it was generated
    # from, the identity key materialize_template_link upserts by. Both
    # NULL for a hand-authored CheckRule.
    template_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), ForeignKey("templates.id", ondelete="CASCADE"))
    source_template_rule_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("template_rules.id", ondelete="CASCADE")
    )
    # Block L3a: OU-scoped rules + GPO precedence. scope_type='ou' pins the
    # rule to an OU (scope_ou_id), inherited down that OU's ltree subtree.
    # `enforced` = GPO "Enforced" (can't be overridden by lower levels,
    # pierces block_inheritance); `link_order` breaks ties within one level
    # (lowest wins). See services/compiler._resolve_gpo_winner.
    scope_ou_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), ForeignKey("ou_nodes.id", ondelete="CASCADE"))
    enforced: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    link_order: Mapped[int] = mapped_column(Integer, nullable=False, default=100)

    __table_args__ = (
        CheckConstraint(
            "comparison IN ('gt', 'lt', 'ge', 'le', 'eq', 'ne')", name="ck_check_rules_comparison"
        ),
        CheckConstraint("condition_logic IN ('AND', 'OR')", name="ck_check_rules_condition_logic"),
        CheckConstraint("scope_type IN ('global', 'group', 'host', 'ou')", name="ck_check_rules_scope_type"),
        CheckConstraint(
            "(scope_type = 'global' AND scope_value IS NULL AND scope_ou_id IS NULL) OR "
            "(scope_type IN ('group', 'host') AND scope_value IS NOT NULL AND scope_ou_id IS NULL) OR "
            "(scope_type = 'ou' AND scope_ou_id IS NOT NULL AND scope_value IS NULL)",
            name="ck_check_rules_scope_value_matches_type",
        ),
    )


class CheckRuleOuLink(Base):
    """Additional OU links for a check rule (threshold policy) beyond its
    primary `scope_ou_id` — so ONE policy can apply to MANY OUs (GPO-style
    multi-link, like OrchestrationPlanLink) instead of being duplicated per
    OU. Resolution (services/monitoring.resolve_effective_rule) unions the
    primary scope_ou_id with every linked OU; for a given host the deepest of
    those OUs on its ancestry decides the rule's level. CASCADE on both sides:
    the link disappears with either the rule or the OU."""

    __tablename__ = "check_rule_ou_links"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    rule_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("check_rules.id", ondelete="CASCADE"), nullable=False
    )
    ou_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("ou_nodes.id", ondelete="CASCADE"), nullable=False
    )
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)

    __table_args__ = (
        UniqueConstraint("rule_id", "ou_id", name="uq_check_rule_ou_links_rule_ou"),
        Index("idx_check_rule_ou_links_rule", "rule_id"),
    )


class HostConfigResource(Base):
    """Block K3 — the desired config VALUES for one file on one host: the
    fleet-side key-value database. Written whenever a config edit is applied
    through the document loop (K1 codec merge / K2 template render); drift is
    this desired `values` re-planned against the host's live observed state.
    `type` is "config" (codec merge) or "template_render" (Class-B); `template`
    holds the inline Jinja2 source for the latter. One row per (agent, path)."""

    __tablename__ = "host_config_resources"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    tenant_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    agent_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("agents.id", ondelete="CASCADE"), nullable=False)
    path: Mapped[str] = mapped_column(String, nullable=False)
    type: Mapped[str] = mapped_column(String, nullable=False, default="config")
    config_format: Mapped[str | None] = mapped_column(String)
    separator: Mapped[str | None] = mapped_column(String)
    values: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)
    template: Mapped[str | None] = mapped_column(Text)
    updated_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)
    updated_by: Mapped[str | None] = mapped_column(String)

    __table_args__ = (
        UniqueConstraint("agent_id", "path", name="uq_host_config_resources_agent_path"),
        Index("idx_host_config_resources_agent", "agent_id"),
    )


class ConfigPolicy(Base):
    """Block K4 — a scoped config resource (values or template+values) applying
    to every host under an OU (scope_ou_id) OR in a host group (host_group_id),
    the config counterpart to a check_rule / orchestration link. A host's
    effective desired config per path is the GPO winner: host-direct
    HostConfigResource > deepest OU policy > group policy. Exactly one of
    scope_ou_id / host_group_id is set; one row per (scope, path)."""

    __tablename__ = "config_policies"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    tenant_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    scope_ou_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), ForeignKey("ou_nodes.id", ondelete="CASCADE"))
    host_group_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), ForeignKey("host_groups.id", ondelete="CASCADE"))
    path: Mapped[str] = mapped_column(String, nullable=False)
    type: Mapped[str] = mapped_column(String, nullable=False, default="config")
    config_format: Mapped[str | None] = mapped_column(String)
    separator: Mapped[str | None] = mapped_column(String)
    values: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)
    template: Mapped[str | None] = mapped_column(Text)
    updated_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)

    __table_args__ = (
        UniqueConstraint("scope_ou_id", "path", name="uq_config_policies_ou_path"),
        UniqueConstraint("host_group_id", "path", name="uq_config_policies_group_path"),
        Index("idx_config_policies_ou", "scope_ou_id"),
        Index("idx_config_policies_group", "host_group_id"),
    )


class Service(Base):
    """The materialized, per-host result of evaluating a CheckRule against
    the most recently polled metric value — CheckMK's own "Service"
    concept (see services/monitoring.py's evaluate_host and docs/plan.md's
    monitoring Block E2). A row with `state != 'OK'` and neither
    acknowledged nor covered by an active Downtime is an active "problem"
    (see api/monitoring.py's GET /api/v1/problems)."""

    __tablename__ = "services"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    agent_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("agents.id"), nullable=False)
    name: Mapped[str] = mapped_column(String, nullable=False)
    metric: Mapped[str] = mapped_column(String, nullable=False)
    state: Mapped[str] = mapped_column(String, nullable=False, default="UNKNOWN")
    value: Mapped[float | None] = mapped_column(Float)
    output: Mapped[str] = mapped_column(Text, nullable=False, default="")
    rule_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), ForeignKey("check_rules.id"))
    last_state_change: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)
    last_checked: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)
    # CheckMK-style state debouncing (Block H7): a non-OK result is `soft`
    # until it recurs `max_attempts` times, then `hard`; only hard non-OK
    # states are real problems. `attempt` is the current consecutive count.
    # `is_flapping` marks a service that changes state too often.
    state_type: Mapped[str] = mapped_column(String, nullable=False, default="hard")
    attempt: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    max_attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=3)
    is_flapping: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    acknowledged: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    ack_comment: Mapped[str | None] = mapped_column(Text)
    ack_by: Mapped[str | None] = mapped_column(String)
    # CheckMK's "acknowledge for a limited time" (Block H5): NULL = the
    # existing indefinite ack; once passed, the ack lapses and the problem
    # resurfaces (enforced lazily by expire_acknowledgements()).
    ack_expires_at: Mapped[datetime | None] = mapped_column(TZ_DATETIME)

    __table_args__ = (
        UniqueConstraint("agent_id", "name", name="uq_services_agent_name"),
        CheckConstraint("state IN ('OK', 'WARN', 'CRIT', 'UNKNOWN')", name="ck_services_state"),
        CheckConstraint("state_type IN ('soft', 'hard')", name="ck_services_state_type"),
        Index("idx_services_agent", "agent_id"),
    )


class ServiceStateHistory(Base):
    """Zustands-Zeitleiste — a TimescaleDB hypertable (see the Alembic
    migration), one row per Service state change, mirroring how Metric/
    ConnectionEvent already separate "current materialized state" from
    "raw history" (see docs/plan.md's monitoring Block E2)."""

    __tablename__ = "service_state_history"

    time: Mapped[datetime] = mapped_column(TZ_DATETIME, nullable=False, primary_key=True)
    agent_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("agents.id"), nullable=False, primary_key=True
    )
    service_name: Mapped[str] = mapped_column(String, nullable=False, primary_key=True)
    state: Mapped[str] = mapped_column(String, nullable=False)
    value: Mapped[float | None] = mapped_column(Float)

    __table_args__ = (Index("idx_service_state_history_agent_service_time", "agent_id", "service_name", "time"),)


class NotificationRule(Base):
    """Who gets told, on which channel, when a service has a confirmed
    (hard) problem or recovery (Block H8). `min_state` is the severity
    floor; host_filter/service_filter are optional substring matches."""

    __tablename__ = "notification_rules"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    name: Mapped[str] = mapped_column(String, nullable=False)
    enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    on_problem: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    on_recovery: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    min_state: Mapped[str] = mapped_column(String, nullable=False, default="WARN")
    host_filter: Mapped[str | None] = mapped_column(String)
    service_filter: Mapped[str | None] = mapped_column(String)
    channel: Mapped[str] = mapped_column(String, nullable=False)  # email|webhook|slack|teams|telegram|pagerduty|discord
    target: Mapped[str] = mapped_column(String, nullable=False)
    # On-call escalation: fire this rule only once a hard problem has stayed
    # unacknowledged this many minutes. NULL = fire immediately on the event
    # (level 0). A chain is several rules with increasing values (0/15/60).
    escalate_after_minutes: Mapped[int | None] = mapped_column(Integer)
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)
    # Block K7: optional subset match against the problem's host's
    # Agent.tags — every key:value pair here must be present on the host
    # (name-only tags stored as "" match a same-name tag of any value).
    # NULL = no tag condition (matches regardless of the host's tags).
    tag_filter: Mapped[dict | None] = mapped_column(JSONB)
    # Block L3a: OU binding + GPO precedence, mirroring CheckRule. ou_id NULL
    # = global (today's behavior); a value scopes the rule to that OU's
    # ltree subtree. enforced/link_order as in CheckRule.
    ou_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), ForeignKey("ou_nodes.id", ondelete="CASCADE"))
    enforced: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    link_order: Mapped[int] = mapped_column(Integer, nullable=False, default=100)
    # Block N1: the shared scope model (services/scope.py). A notification is
    # an ADDITIVE filter — every rule whose scope covers the event fires — so
    # scope here is a target, not a precedence level. global (all) | ou
    # (ou_id, subtree) | group (scope_value) | host (scope_value=agent) |
    # service (scope_value=agent + scope_service_name) | policy
    # (scope_plan_id = a plan assigned to the host). host_filter/service_filter
    # remain optional extra substring filters.
    scope_type: Mapped[str] = mapped_column(String, nullable=False, default="global")
    scope_value: Mapped[str | None] = mapped_column(String)
    scope_service_name: Mapped[str | None] = mapped_column(String)
    scope_plan_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("orchestration_plans.id", ondelete="CASCADE")
    )

    __table_args__ = (
        CheckConstraint(
            "channel IN ('email', 'webhook', 'slack', 'teams', 'telegram', 'pagerduty', 'discord')",
            name="ck_notification_rules_channel",
        ),
        CheckConstraint("min_state IN ('WARN', 'CRIT', 'UNKNOWN')", name="ck_notification_rules_min_state"),
        CheckConstraint(
            "scope_type IN ('global', 'ou', 'group', 'host', 'service', 'policy')",
            name="ck_notification_rules_scope_type",
        ),
    )


class Notification(Base):
    """One notification send attempt — the audit log behind Monitor →
    Notifications (Block H8)."""

    __tablename__ = "notifications"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    rule_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("notification_rules.id", ondelete="SET NULL")
    )
    agent_name: Mapped[str] = mapped_column(String, nullable=False)
    service_name: Mapped[str] = mapped_column(String, nullable=False)
    event: Mapped[str] = mapped_column(String, nullable=False)  # problem | recovery
    state: Mapped[str] = mapped_column(String, nullable=False)
    channel: Mapped[str] = mapped_column(String, nullable=False)
    target: Mapped[str] = mapped_column(String, nullable=False)
    status: Mapped[str] = mapped_column(String, nullable=False)  # sent | failed
    error: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)

    __table_args__ = (Index("idx_notifications_created", "created_at"),)


class Downtime(Base):
    """A scheduled maintenance window (see docs/plan.md's monitoring Block
    E2) — `service_name=NULL` means the whole host, matching CheckMK's own
    host-vs-service downtime distinction."""

    __tablename__ = "downtimes"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    agent_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("agents.id"), nullable=False)
    service_name: Mapped[str | None] = mapped_column(String)
    starts_at: Mapped[datetime] = mapped_column(TZ_DATETIME, nullable=False)
    ends_at: Mapped[datetime] = mapped_column(TZ_DATETIME, nullable=False)
    comment: Mapped[str] = mapped_column(Text, nullable=False, default="")
    created_by: Mapped[str | None] = mapped_column(String)
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)

    __table_args__ = (Index("idx_downtimes_agent_window", "agent_id", "starts_at", "ends_at"),)


class Dashboard(Base):
    """A named operator dashboard (Checkmk-style dashboard management). Each
    user owns several; one is `is_default`. `source` distinguishes a hand-built
    dashboard ('manual') from an AI-generated one ('ai', which keeps its
    `prompt`). `context` holds the dashboard's filter context (Block B) — a
    {filter_ident: {var: value}} map applied to every widget's query. Widgets
    belong to a dashboard via DashboardWidget.dashboard_id; unifying the old
    per-user single grid + the separate AI blob into one model."""

    __tablename__ = "dashboards"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    username: Mapped[str] = mapped_column(String, nullable=False)
    name: Mapped[str] = mapped_column(String, nullable=False)
    is_default: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    source: Mapped[str] = mapped_column(String, nullable=False, default="manual")  # manual | ai
    prompt: Mapped[str] = mapped_column(String, nullable=False, default="")
    context: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)

    widgets: Mapped[list["DashboardWidget"]] = relationship(
        back_populates="dashboard", cascade="all, delete-orphan"
    )

    __table_args__ = (
        UniqueConstraint("username", "name", name="uq_dashboards_username_name"),
        Index("idx_dashboards_username", "username"),
    )


class DashboardWidget(Base):
    """One GridStack widget on an operator dashboard (see docs/plan.md's
    monitoring-cockpit ergänzung Block F5, modeled on CentralStation's
    dashboard-widget shape). Belongs to a Dashboard via `dashboard_id`;
    `username` is retained for scoping/back-compat. An AI-generated widget
    carries its inline data in `config['static']` (rendered as-is) instead of
    being computed server-side."""

    __tablename__ = "dashboard_widgets"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    dashboard_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("dashboards.id", ondelete="CASCADE"), nullable=True
    )
    username: Mapped[str] = mapped_column(String, nullable=False)
    widget_type: Mapped[str] = mapped_column(String, nullable=False)
    title: Mapped[str] = mapped_column(String, nullable=False)
    gs_x: Mapped[int] = mapped_column(nullable=False, default=0)
    gs_y: Mapped[int] = mapped_column(nullable=False, default=0)
    gs_w: Mapped[int] = mapped_column(nullable=False, default=4)
    gs_h: Mapped[int] = mapped_column(nullable=False, default=3)
    config: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)
    pinned: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    hidden: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)

    dashboard: Mapped["Dashboard | None"] = relationship(back_populates="widgets")

    __table_args__ = (
        CheckConstraint(
            "widget_type IN ('top_hosts', 'problems', 'gauge', 'timeseries', 'donut', 'stat', "
            "'bar', 'table', 'status_tiles', 'progress', 'ai_summary', 'war_room', 'log', 'callout')",
            name="ck_dashboard_widgets_type",
        ),
        Index("idx_dashboard_widgets_username", "username"),
        Index("idx_dashboard_widgets_dashboard", "dashboard_id"),
    )


class ChatSession(Base):
    """Block K — one AI chat-console conversation. Keyed by username (like
    dashboard_widgets), records which backend (claude_cli/codex/hermes_web)
    it uses. Messages are its ordered children."""

    __tablename__ = "chat_sessions"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    username: Mapped[str] = mapped_column(String, nullable=False)
    label: Mapped[str | None] = mapped_column(String)
    backend: Mapped[str] = mapped_column(String, nullable=False, default="claude_cli")
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)

    messages: Mapped[list["ChatMessage"]] = relationship(
        back_populates="session", cascade="all, delete-orphan", order_by="ChatMessage.seq"
    )

    __table_args__ = (Index("idx_chat_sessions_username", "username"),)


class ChatMessage(Base):
    """Block K — one turn in a chat session (OpenAI {role, content} shape),
    ordered by `seq`. `meta` carries per-message extras (tool calls, emitted
    widget specs) for replay."""

    __tablename__ = "chat_messages"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    session_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("chat_sessions.id", ondelete="CASCADE"), nullable=False
    )
    seq: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    role: Mapped[str] = mapped_column(String, nullable=False)  # user | assistant | system
    content: Mapped[str] = mapped_column(String, nullable=False, default="")
    meta: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)

    session: Mapped["ChatSession"] = relationship(back_populates="messages")

    __table_args__ = (Index("idx_chat_messages_session", "session_id", "seq"),)


class ChatPreference(Base):
    """Block K — per-user chat console settings (one row per username): the
    default backend and per-backend model choices. Every user configures their
    own console independently; the OAuth tokens themselves live in the user's
    bind-mounted home dir (see services/chat_home.py), not the DB."""

    __tablename__ = "chat_preferences"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    username: Mapped[str] = mapped_column(String, nullable=False, unique=True)
    default_backend: Mapped[str] = mapped_column(String, nullable=False, default="claude_cli")
    models: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)  # {backend: model}
    # Console LLM endpoint config, set from Settings (overrides the deploy-time
    # default so the hermes/OpenAI-compatible endpoint isn't pinned in env).
    hermes_base_url: Mapped[str | None] = mapped_column(String)
    hermes_model: Mapped[str | None] = mapped_column(String)
    updated_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)


class GeneratedDashboard(Base):
    """Block W2 — a per-user AI-generated dashboard (like CentralStation's
    generative designer). The AI designs a set of inline-data widget specs
    ([{widget_type, title, data, gs_w, gs_h}]); they're stored whole (one row
    per user, latest wins) and rendered by the shared widget component. Kept
    separate from the operator's config-driven dashboard_widgets."""

    __tablename__ = "generated_dashboards"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid())
    username: Mapped[str] = mapped_column(String, nullable=False, unique=True)
    prompt: Mapped[str] = mapped_column(String, nullable=False, default="")
    widgets: Mapped[list] = mapped_column(JSONB, nullable=False, default=list)
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)
