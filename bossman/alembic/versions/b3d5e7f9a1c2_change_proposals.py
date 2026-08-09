"""change_proposals — AI change-proposal approval queue

Human-in-the-loop gate for autonomous changes: an AI-decided apply files a
proposal carrying the dry-run preview; a human approves (→apply) or rejects.

Revision ID: b3d5e7f9a1c2
Revises: a2f4c6d8e0b1
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision = "b3d5e7f9a1c2"
down_revision = "a2f4c6d8e0b1"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "change_proposals",
        sa.Column("id", postgresql.UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("tenant_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False),
        sa.Column("kind", sa.String(), nullable=False),
        sa.Column("agent_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("agents.id", ondelete="SET NULL"), nullable=True),
        sa.Column("host", sa.String(), nullable=False, server_default=""),
        sa.Column("title", sa.String(), nullable=False, server_default=""),
        sa.Column("payload", postgresql.JSONB(), nullable=False, server_default="{}"),
        sa.Column("preview", postgresql.JSONB(), nullable=False, server_default="{}"),
        sa.Column("requested_by", sa.String(), nullable=True),
        sa.Column("status", sa.String(), nullable=False, server_default="pending"),
        sa.Column("apply_result", postgresql.JSONB(), nullable=False, server_default="{}"),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("decided_by", sa.String(), nullable=True),
        sa.Column("decided_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index("idx_change_proposals_status", "change_proposals", ["status", "created_at"])


def downgrade() -> None:
    op.drop_index("idx_change_proposals_status", table_name="change_proposals")
    op.drop_table("change_proposals")
