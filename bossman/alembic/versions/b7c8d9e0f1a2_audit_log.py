"""audit_log — unified who-did-what-when audit trail

Revision ID: b7c8d9e0f1a2
Revises: a6b7c8d9e0f1
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision = "b7c8d9e0f1a2"
down_revision = "a6b7c8d9e0f1"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "audit_log",
        sa.Column("id", sa.BigInteger(), autoincrement=True, primary_key=True),
        sa.Column("tenant_id", UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False),
        sa.Column("at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("actor", sa.String(), nullable=False, server_default="anonymous"),
        sa.Column("actor_kind", sa.String(), nullable=True),
        sa.Column("action", sa.String(), nullable=False),
        sa.Column("category", sa.String(), nullable=False, server_default="other"),
        sa.Column("method", sa.String(), nullable=True),
        sa.Column("path", sa.String(), nullable=True),
        sa.Column("target", sa.String(), nullable=True),
        sa.Column("status", sa.String(), nullable=False, server_default="ok"),
        sa.Column("status_code", sa.Integer(), nullable=True),
        sa.Column("source_ip", sa.String(), nullable=True),
        sa.Column("detail", JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")),
    )
    op.create_index("idx_audit_at", "audit_log", ["at"])
    op.create_index("idx_audit_actor", "audit_log", ["actor"])
    op.create_index("idx_audit_category", "audit_log", ["category"])


def downgrade() -> None:
    op.drop_index("idx_audit_category", table_name="audit_log")
    op.drop_index("idx_audit_actor", table_name="audit_log")
    op.drop_index("idx_audit_at", table_name="audit_log")
    op.drop_table("audit_log")
