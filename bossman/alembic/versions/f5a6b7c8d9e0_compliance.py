"""compliance — software inventory compliance rules + per-host results

Revision ID: f5a6b7c8d9e0
Revises: e4f5a6b7c8d9
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision = "f5a6b7c8d9e0"
down_revision = "e4f5a6b7c8d9"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "compliance_rules",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("tenant_id", UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("enabled", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("scope_type", sa.String(), nullable=False),
        sa.Column("agent_id", UUID(as_uuid=True), sa.ForeignKey("agents.id", ondelete="CASCADE"), nullable=True),
        sa.Column("host_group_id", UUID(as_uuid=True), sa.ForeignKey("host_groups.id", ondelete="CASCADE"), nullable=True),
        sa.Column("ou_id", UUID(as_uuid=True), sa.ForeignKey("ou_nodes.id", ondelete="CASCADE"), nullable=True),
        sa.Column("required", JSONB(), nullable=False, server_default=sa.text("'[]'::jsonb")),
        sa.Column("forbidden", JSONB(), nullable=False, server_default=sa.text("'[]'::jsonb")),
        sa.Column("severity", sa.String(), nullable=False, server_default="CRIT"),
        sa.Column("created_by", sa.String(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.CheckConstraint("scope_type IN ('global', 'host', 'group', 'ou')", name="ck_compliance_scope"),
        sa.CheckConstraint("severity IN ('WARN', 'CRIT')", name="ck_compliance_severity"),
    )
    op.create_table(
        "compliance_results",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("tenant_id", UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False),
        sa.Column("rule_id", UUID(as_uuid=True), sa.ForeignKey("compliance_rules.id", ondelete="CASCADE"), nullable=False),
        sa.Column("agent_id", UUID(as_uuid=True), sa.ForeignKey("agents.id", ondelete="CASCADE"), nullable=False),
        sa.Column("status", sa.String(), nullable=False, server_default="OK"),
        sa.Column("violations", JSONB(), nullable=False, server_default=sa.text("'[]'::jsonb")),
        sa.Column("evaluated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("rule_id", "agent_id", name="uq_compliance_result"),
    )
    op.create_index("idx_compliance_result_agent", "compliance_results", ["agent_id"])


def downgrade() -> None:
    op.drop_index("idx_compliance_result_agent", table_name="compliance_results")
    op.drop_table("compliance_results")
    op.drop_table("compliance_rules")
