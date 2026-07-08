"""policy/orchestration L4: transactional outbox + agent desired-state delivery

Revision ID: e7a2b6c04d19
Revises: d4c8e1f9a3b7
Create Date: 2026-07-08

Block L4 (controller half of desired-state delivery — see
docs/policy-orchestration-architecture.md §6–§8). Additive, no destructive
host changes: the controller computes the desired state (compiled_host_state,
L1), records a change signal in a transactional outbox, a reconciler worker
recompiles affected hosts and enqueues a delivery, and the agent PULLs its
desired state and ACKs it. The agent-side apply (Go) is a later, separately
authorized block; nothing here mutates a real host.

  * policy_events        — what changed (ids), NOT the full config
  * controller_outbox    — retryable work queue (FOR UPDATE SKIP LOCKED)
  * agent_config_delivery — one row per (agent, generation) delivery attempt
  * agent_acks           — the agent's ack/nack per generation
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision: str = "e7a2b6c04d19"
down_revision: Union[str, Sequence[str], None] = "d4c8e1f9a3b7"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "policy_events",
        sa.Column("id", sa.BigInteger(), autoincrement=True, nullable=False),
        sa.Column("tenant_id", UUID(as_uuid=True), nullable=False),
        sa.Column("kind", sa.String(), nullable=False),
        sa.Column("payload", JSONB(astext_type=sa.Text()), nullable=False, server_default="{}"),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.ForeignKeyConstraint(["tenant_id"], ["tenants.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.CheckConstraint(
            "kind IN ('rule_changed', 'ou_changed', 'host_moved', 'label_changed', 'plan_changed', 'link_changed')",
            name="ck_policy_events_kind",
        ),
    )
    op.create_table(
        "controller_outbox",
        sa.Column("id", sa.BigInteger(), autoincrement=True, nullable=False),
        sa.Column("tenant_id", UUID(as_uuid=True), nullable=False),
        sa.Column("event_id", sa.BigInteger(), nullable=False),
        sa.Column("status", sa.String(), nullable=False, server_default="pending"),
        sa.Column("attempts", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("last_error", sa.Text(), nullable=True),
        sa.Column("available_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("processed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.ForeignKeyConstraint(["tenant_id"], ["tenants.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["event_id"], ["policy_events.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.CheckConstraint("status IN ('pending', 'processing', 'done', 'failed')", name="ck_controller_outbox_status"),
    )
    op.create_index(
        "ix_controller_outbox_ready", "controller_outbox", ["available_at"], postgresql_where=sa.text("status = 'pending'")
    )
    op.create_table(
        "agent_config_delivery",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), nullable=False),
        sa.Column("tenant_id", UUID(as_uuid=True), nullable=False),
        sa.Column("agent_id", UUID(as_uuid=True), nullable=False),
        sa.Column("generation", sa.BigInteger(), nullable=False),
        sa.Column("config_hash", sa.String(), nullable=False),
        sa.Column("status", sa.String(), nullable=False, server_default="pending"),
        sa.Column("attempts", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("last_error", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.ForeignKeyConstraint(["tenant_id"], ["tenants.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["agent_id"], ["agents.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("agent_id", "generation", name="uq_agent_config_delivery_agent_generation"),
        sa.CheckConstraint(
            "status IN ('pending', 'sent', 'acked', 'nacked', 'failed')", name="ck_agent_config_delivery_status"
        ),
    )
    op.create_table(
        "agent_acks",
        sa.Column("id", sa.BigInteger(), autoincrement=True, nullable=False),
        sa.Column("tenant_id", UUID(as_uuid=True), nullable=False),
        sa.Column("agent_id", UUID(as_uuid=True), nullable=False),
        sa.Column("generation", sa.BigInteger(), nullable=False),
        sa.Column("result", sa.String(), nullable=False),
        sa.Column("detail", JSONB(astext_type=sa.Text()), nullable=False, server_default="{}"),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.ForeignKeyConstraint(["tenant_id"], ["tenants.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["agent_id"], ["agents.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.CheckConstraint("result IN ('ack', 'nack')", name="ck_agent_acks_result"),
    )


def downgrade() -> None:
    op.drop_table("agent_acks")
    op.drop_table("agent_config_delivery")
    op.drop_index("ix_controller_outbox_ready", table_name="controller_outbox")
    op.drop_table("controller_outbox")
    op.drop_table("policy_events")
