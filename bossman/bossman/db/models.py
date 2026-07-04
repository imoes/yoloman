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

from sqlalchemy import BigInteger, CheckConstraint, DateTime, ForeignKey, Index, Integer, String, UniqueConstraint
from sqlalchemy.dialects.postgresql import INET, JSONB, UUID
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship
from sqlalchemy.sql import func

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
