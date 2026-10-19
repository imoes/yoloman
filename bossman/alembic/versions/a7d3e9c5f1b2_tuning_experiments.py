"""tuning_experiments — A/B measurements of a kernel tunable (docs/kernel-tuning.md, block 5).

Revision ID: a7d3e9c5f1b2
Revises: f2c8d4a6b1e3
Create Date: 2026-10-18
"""

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = "a7d3e9c5f1b2"
down_revision = "f2c8d4a6b1e3"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "tuning_experiments",
        sa.Column("id", postgresql.UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("agent_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("agents.id", ondelete="CASCADE"), nullable=False),
        sa.Column("hostname", sa.String(), nullable=False),
        sa.Column("tunable", sa.String(), nullable=False),
        sa.Column("candidate", postgresql.JSONB(), nullable=False, server_default="{}"),
        sa.Column("profile", sa.String(), nullable=False),
        sa.Column("runs", sa.Integer(), nullable=False, server_default="5"),
        sa.Column("hypothesis", sa.Text(), nullable=False, server_default=""),
        # planned | running | done | aborted
        sa.Column("status", sa.String(), nullable=False, server_default="planned"),
        # better | worse | no_difference | inconclusive | aborted
        sa.Column("verdict", sa.String()),
        sa.Column("measurements", postgresql.JSONB(), nullable=False, server_default="[]"),
        sa.Column("summary", postgresql.JSONB()),
        sa.Column("undo", postgresql.JSONB()),
        sa.Column("rehearsal", postgresql.JSONB()),
        sa.Column("error", sa.Text()),
        sa.Column("requested_by", sa.String(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("started_at", sa.DateTime(timezone=True)),
        sa.Column("finished_at", sa.DateTime(timezone=True)),
        sa.CheckConstraint("status IN ('planned','running','done','aborted')", name="ck_tuning_experiments_status"),
        sa.CheckConstraint("verdict IS NULL OR verdict IN ('better','worse','no_difference','inconclusive','aborted')",
                           name="ck_tuning_experiments_verdict"),
    )
    op.create_index("ix_tuning_experiments_agent", "tuning_experiments", ["agent_id", "created_at"])


def downgrade() -> None:
    op.drop_index("ix_tuning_experiments_agent", table_name="tuning_experiments")
    op.drop_table("tuning_experiments")
