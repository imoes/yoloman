"""Deploy finalizations — the runbook a deployment runs once its new host's agent first reports (image restore and
network install alike).

Revision ID: d4a8b2c6e9f1
Revises: c3f7a9e1d2b4
Create Date: 2026-10-18
"""

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = "d4a8b2c6e9f1"
down_revision = "c3f7a9e1d2b4"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "deploy_finalizations",
        sa.Column("id", postgresql.UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("agent_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("agents.id", ondelete="CASCADE"), nullable=False),
        sa.Column("hostname", sa.String(), nullable=False),
        sa.Column("runbook", sa.String(), nullable=False),
        sa.Column("variables", postgresql.JSONB(), nullable=False, server_default="{}"),
        sa.Column("apply", sa.Boolean(), nullable=False, server_default=sa.text("false")),
        # waiting (for the host's first report) | running | done | failed | cancelled
        sa.Column("status", sa.String(), nullable=False, server_default="waiting"),
        sa.Column("result", postgresql.JSONB()),
        sa.Column("error", sa.Text()),
        sa.Column("requested_by", sa.String(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("started_at", sa.DateTime(timezone=True)),
        sa.Column("finished_at", sa.DateTime(timezone=True)),
    )
    op.create_index("ix_deploy_finalizations_status", "deploy_finalizations", ["status"])


def downgrade() -> None:
    op.drop_index("ix_deploy_finalizations_status", table_name="deploy_finalizations")
    op.drop_table("deploy_finalizations")
