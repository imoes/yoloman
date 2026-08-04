"""deployment_templates: reusable deploy recipes (image + grow policy + network + roles)

A deployment template bundles everything a provisioning run needs except the per-machine hostname/MAC, so
the wizard can prefill from one and the operator only fills in the target.

Revision ID: c9f2a7b4e1d8
Revises: b8e1c6a2d3f7
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "c9f2a7b4e1d8"
down_revision = "b8e1c6a2d3f7"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "deployment_templates",
        sa.Column("id", postgresql.UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("tenant_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("description", sa.Text(), nullable=False, server_default=""),
        sa.Column("image_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("grow_mode", sa.String(), nullable=False, server_default="percent"),
        sa.Column("grow_policy", postgresql.JSONB(), nullable=False, server_default="{}"),
        sa.Column("network", postgresql.JSONB(), nullable=False, server_default="{}"),
        sa.Column("roles", postgresql.JSONB(), nullable=False, server_default="[]"),
        sa.Column("created_by", sa.String(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("tenant_id", "name", name="uq_deployment_templates_name"),
        sa.CheckConstraint("grow_mode IN ('percent', 'absolute')", name="ck_deployment_templates_grow_mode"),
    )


def downgrade() -> None:
    op.drop_table("deployment_templates")
