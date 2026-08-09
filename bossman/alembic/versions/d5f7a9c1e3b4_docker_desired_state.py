"""docker_desired_state — versioned container desired state (generations)

Revision ID: d5f7a9c1e3b4
Revises: c4e6f8a0b2d3
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision = "d5f7a9c1e3b4"
down_revision = "c4e6f8a0b2d3"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "docker_desired_state",
        sa.Column("id", postgresql.UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("tenant_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False),
        sa.Column("agent_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("agents.id", ondelete="CASCADE"), nullable=False),
        sa.Column("generation", sa.BigInteger(), nullable=False),
        sa.Column("spec", postgresql.JSONB(), nullable=False, server_default="{}"),
        sa.Column("config_hash", sa.String(), nullable=False),
        sa.Column("source", sa.String(), nullable=False, server_default="discovered"),
        sa.Column("note", sa.String(), nullable=True),
        sa.Column("created_by", sa.String(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.UniqueConstraint("agent_id", "generation", name="uq_docker_desired_agent_generation"),
    )
    op.create_index("idx_docker_desired_agent", "docker_desired_state", ["agent_id", "generation"])


def downgrade() -> None:
    op.drop_index("idx_docker_desired_agent", table_name="docker_desired_state")
    op.drop_table("docker_desired_state")
