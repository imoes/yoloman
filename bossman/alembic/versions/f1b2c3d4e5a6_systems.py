"""systems + system_members — the System object (apps + wiring above a host)

Revision ID: f1b2c3d4e5a6
Revises: a7b3c9d1e2f4
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision = "f1b2c3d4e5a6"
down_revision = "a7b3c9d1e2f4"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "systems",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("name", sa.String(), nullable=False, unique=True),
        sa.Column("description", sa.String(), nullable=True),
        sa.Column("seed_agent_id", UUID(as_uuid=True), sa.ForeignKey("agents.id", ondelete="SET NULL"), nullable=True),
        sa.Column("edges", JSONB(), nullable=False, server_default=sa.text("'[]'::jsonb")),
        sa.Column("created_by", sa.String(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_table(
        "system_members",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("system_id", UUID(as_uuid=True), sa.ForeignKey("systems.id", ondelete="CASCADE"), nullable=False),
        sa.Column("target", sa.String(), nullable=False),
        sa.Column("app", sa.String(), nullable=False),
        sa.Column("role_in_system", sa.String(), nullable=True),
        sa.Column("config", JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index("ix_system_members_system_id", "system_members", ["system_id"])


def downgrade() -> None:
    op.drop_index("ix_system_members_system_id", table_name="system_members")
    op.drop_table("system_members")
    op.drop_table("systems")
