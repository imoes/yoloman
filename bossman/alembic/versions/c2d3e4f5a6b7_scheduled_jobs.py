"""scheduled_jobs — recurring runbook scheduler

Revision ID: c2d3e4f5a6b7
Revises: b1c2d3e4f5a6
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision = "c2d3e4f5a6b7"
down_revision = "b1c2d3e4f5a6"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "scheduled_jobs",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("tenant_id", UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("enabled", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("cron", sa.String(), nullable=False),
        sa.Column("runbook_name", sa.String(), nullable=False),
        sa.Column("scope_type", sa.String(), nullable=False),
        sa.Column("agent_id", UUID(as_uuid=True), sa.ForeignKey("agents.id", ondelete="CASCADE"), nullable=True),
        sa.Column("host_group_id", UUID(as_uuid=True), sa.ForeignKey("host_groups.id", ondelete="CASCADE"), nullable=True),
        sa.Column("ou_id", UUID(as_uuid=True), sa.ForeignKey("ou_nodes.id", ondelete="CASCADE"), nullable=True),
        sa.Column("variables", JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("dry_run", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("last_run_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_status", sa.String(), nullable=True),
        sa.Column("last_detail", sa.Text(), nullable=True),
        sa.Column("created_by", sa.String(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.CheckConstraint("scope_type IN ('host', 'group', 'ou')", name="ck_scheduled_jobs_scope_type"),
    )
    op.create_index("idx_scheduled_jobs_enabled", "scheduled_jobs", ["enabled"])


def downgrade() -> None:
    op.drop_index("idx_scheduled_jobs_enabled", table_name="scheduled_jobs")
    op.drop_table("scheduled_jobs")
