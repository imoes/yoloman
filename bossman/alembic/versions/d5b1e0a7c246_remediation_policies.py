"""remediation_policies + remediation_runs — event-driven self-healing on a check

A check (service) entering a hard problem state can trigger a parameter-driven
remediation runbook (restart a service/container, clear logs, …), scoped like
any policy, with per-host rate limiting and auto/propose modes. remediation_runs
is the audit + rate-limit source.

Revision ID: d5b1e0a7c246
Revises: c3f8a1d29b64
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision = "d5b1e0a7c246"
down_revision = "c3f8a1d29b64"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "remediation_policies",
        sa.Column("id", postgresql.UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("tenant_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("match_service_name", sa.String(), nullable=False, server_default=""),
        sa.Column("scope_type", sa.String(), nullable=False, server_default="global"),
        sa.Column("ou_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("ou_nodes.id", ondelete="CASCADE"), nullable=True),
        sa.Column("host_group_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("host_groups.id", ondelete="CASCADE"), nullable=True),
        sa.Column("agent_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("agents.id", ondelete="CASCADE"), nullable=True),
        sa.Column("conditions", postgresql.JSONB(astext_type=sa.Text()), nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("runbook_name", sa.String(), nullable=False),
        sa.Column("params", postgresql.JSONB(astext_type=sa.Text()), nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("max_per_hour", sa.Integer(), nullable=False, server_default="3"),
        sa.Column("mode", sa.String(), nullable=False, server_default="auto"),
        sa.Column("enabled", sa.Boolean(), nullable=False, server_default=sa.text("true")),
        sa.Column("created_by", sa.String(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.CheckConstraint("scope_type IN ('global', 'ou', 'group', 'host')", name="ck_remediation_scope"),
        sa.CheckConstraint("mode IN ('auto', 'propose')", name="ck_remediation_mode"),
    )
    op.create_index("idx_remediation_service", "remediation_policies", ["match_service_name"])
    op.create_table(
        "remediation_runs",
        sa.Column("id", postgresql.UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("tenant_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False),
        sa.Column("policy_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("remediation_policies.id", ondelete="SET NULL"), nullable=True),
        sa.Column("agent_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("agents.id", ondelete="SET NULL"), nullable=True),
        sa.Column("service_name", sa.String(), nullable=False, server_default=""),
        sa.Column("runbook_name", sa.String(), nullable=False, server_default=""),
        sa.Column("status", sa.String(), nullable=False),
        sa.Column("detail", sa.Text(), nullable=True),
        sa.Column("at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index("idx_remediation_runs_recent", "remediation_runs", ["policy_id", "agent_id", "at"])


def downgrade() -> None:
    op.drop_table("remediation_runs")
    op.drop_index("idx_remediation_service", table_name="remediation_policies")
    op.drop_table("remediation_policies")
