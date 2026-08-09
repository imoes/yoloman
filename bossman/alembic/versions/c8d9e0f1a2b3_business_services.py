"""business_services — logical/BI service aggregation

Revision ID: c8d9e0f1a2b3
Revises: b7c8d9e0f1a2
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision = "c8d9e0f1a2b3"
down_revision = "b7c8d9e0f1a2"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "business_services",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("tenant_id", UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("description", sa.String(), nullable=True),
        sa.Column("enabled", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("members", JSONB(), nullable=False, server_default=sa.text("'[]'::jsonb")),
        sa.Column("logic", sa.String(), nullable=False, server_default="all"),
        sa.Column("status", sa.String(), nullable=False, server_default="UNKNOWN"),
        sa.Column("summary", JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("last_evaluated_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_by", sa.String(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.CheckConstraint("logic IN ('all', 'any')", name="ck_business_service_logic"),
        sa.CheckConstraint("status IN ('OK', 'WARN', 'CRIT', 'UNKNOWN')", name="ck_business_service_status"),
    )


def downgrade() -> None:
    op.drop_table("business_services")
