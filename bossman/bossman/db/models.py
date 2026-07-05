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
)
from sqlalchemy.dialects.postgresql import ARRAY, INET, JSONB, UUID
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship
from sqlalchemy.sql import func

# Embedding dimension for the chunk-similarity cache's vector column (see
# docs/plan.md's "Chunk-similarity embedding cache") — the bge-m3 model
# behind the currently configured embedding endpoint. A column type can't
# read Settings at import time, so this is a plain constant, matching the
# migration's own hardcoded `vector(1024)`; switching embedding models
# means updating both together and re-embedding everything, since vectors
# from different models aren't comparable.
CHUNK_EMBEDDING_DIM = 1024

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
    mode: Mapped[str] = mapped_column(String, nullable=False, default="standalone")
    enrollment_state: Mapped[str] = mapped_column(String, nullable=False, default="pending")
    enrolled_at: Mapped[datetime | None] = mapped_column(TZ_DATETIME)
    last_seen_at: Mapped[datetime | None] = mapped_column(TZ_DATETIME)
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)
    agent_metadata: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)

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
    enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    created_at: Mapped[datetime] = mapped_column(TZ_DATETIME, server_default=func.now(), nullable=False)

    __table_args__ = (
        CheckConstraint(
            "comparison IN ('gt', 'lt', 'ge', 'le', 'eq', 'ne')", name="ck_check_rules_comparison"
        ),
        CheckConstraint("scope_type IN ('global', 'group', 'host')", name="ck_check_rules_scope_type"),
        CheckConstraint(
            "(scope_type = 'global' AND scope_value IS NULL) OR "
            "(scope_type IN ('group', 'host') AND scope_value IS NOT NULL)",
            name="ck_check_rules_scope_value_matches_type",
        ),
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
    acknowledged: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    ack_comment: Mapped[str | None] = mapped_column(Text)
    ack_by: Mapped[str | None] = mapped_column(String)

    __table_args__ = (
        UniqueConstraint("agent_id", "name", name="uq_services_agent_name"),
        CheckConstraint("state IN ('OK', 'WARN', 'CRIT', 'UNKNOWN')", name="ck_services_state"),
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
