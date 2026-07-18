"""cert_targets — certificate / expiry inventory

Revision ID: a6b7c8d9e0f1
Revises: f5a6b7c8d9e0
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision = "a6b7c8d9e0f1"
down_revision = "f5a6b7c8d9e0"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "cert_targets",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("tenant_id", UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("enabled", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("kind", sa.String(), nullable=False, server_default="tls"),
        sa.Column("endpoint", sa.String(), nullable=False, server_default=""),
        sa.Column("warn_days", sa.Integer(), nullable=False, server_default="30"),
        sa.Column("crit_days", sa.Integer(), nullable=False, server_default="7"),
        sa.Column("subject", sa.String(), nullable=True),
        sa.Column("issuer", sa.String(), nullable=True),
        sa.Column("serial", sa.String(), nullable=True),
        sa.Column("not_before", sa.DateTime(timezone=True), nullable=True),
        sa.Column("not_after", sa.DateTime(timezone=True), nullable=True),
        sa.Column("sans", JSONB(), nullable=False, server_default=sa.text("'[]'::jsonb")),
        sa.Column("days_left", sa.Integer(), nullable=True),
        sa.Column("status", sa.String(), nullable=False, server_default="unknown"),
        sa.Column("last_error", sa.String(), nullable=True),
        sa.Column("last_checked_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_by", sa.String(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.CheckConstraint("kind IN ('tls', 'manual')", name="ck_cert_kind"),
        sa.CheckConstraint(
            "status IN ('ok', 'warning', 'critical', 'expired', 'error', 'unknown')", name="ck_cert_status"
        ),
    )


def downgrade() -> None:
    op.drop_table("cert_targets")
