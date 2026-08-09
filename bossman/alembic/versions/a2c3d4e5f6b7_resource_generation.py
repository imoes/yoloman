"""resource_generation — versioned apply/rollback for any Resource/Deployable

Revision ID: a2c3d4e5f6b7
Revises: f1b2c3d4e5a6
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision = "a2c3d4e5f6b7"
down_revision = "f1b2c3d4e5a6"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "resource_generation",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("resource_key", sa.String(), nullable=False),
        sa.Column("resource_type", sa.String(), nullable=False),
        sa.Column("generation", sa.Integer(), nullable=False),
        sa.Column("spec", JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("applied_by", sa.String(), nullable=True),
        sa.Column("note", sa.String(), nullable=True),
        sa.Column("applied_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("resource_key", "generation", name="uq_resource_generation"),
    )
    op.create_index("ix_resource_generation_resource_key", "resource_generation", ["resource_key"])


def downgrade() -> None:
    op.drop_index("ix_resource_generation_resource_key", table_name="resource_generation")
    op.drop_table("resource_generation")
