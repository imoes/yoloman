"""deployment_runs: multi-host deployment aggregate

One row per multi-host deployment (a plan/runbook fanned out across a resolved
target set), grouping the per-host child runs it spawned.

Revision ID: a7b8c9d0e1f2
Revises: f6a7b8c9d0e1
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import ARRAY, JSONB, UUID

revision = "a7b8c9d0e1f2"
down_revision = "f6a7b8c9d0e1"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "deployment_runs",
        sa.Column("id", UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")),
        sa.Column("tenant_id", UUID(as_uuid=True), nullable=False),
        sa.Column("kind", sa.String(), nullable=False),
        sa.Column("target_ref", sa.String(), nullable=False),
        sa.Column("dry_run", sa.Boolean(), nullable=False, server_default=sa.text("false")),
        sa.Column("status", sa.String(), nullable=False, server_default="running"),
        sa.Column("total_hosts", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("ok_hosts", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("failed_hosts", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("unknown_hostnames", ARRAY(sa.String()), nullable=False, server_default="{}"),
        sa.Column("results", JSONB(), nullable=False, server_default="[]"),
        sa.Column("requested_by", sa.String(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.CheckConstraint("status IN ('running', 'ok', 'partial', 'failed')", name="ck_deployment_runs_status"),
        sa.CheckConstraint("kind IN ('plan', 'stored_plan', 'runbook')", name="ck_deployment_runs_kind"),
    )
    op.create_index("ix_deployment_runs_created_at", "deployment_runs", ["created_at"])


def downgrade() -> None:
    op.drop_index("ix_deployment_runs_created_at", table_name="deployment_runs")
    op.drop_table("deployment_runs")
