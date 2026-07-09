"""canonical prefix-keyed plan document store

Revision ID: a3d7f0c2b915
Revises: f1a9c2d38e64
Create Date: 2026-07-09

The `plans` table (docs/zielbestimmung.md principle 4): one canonical,
prefix-keyed JSONB store for every deployment plan — the (coerced) raw dict
plan_loader.build_plan_from_raw consumes, i.e. "all formats converted to
JSON". Keyed by (tenant_id, prefix, name, version); content-addressed via
source_hash + content_hash. Additive; unifies the two prior plan worlds
(file-based plans_dir vs. orchestration_plans) into one store.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision: str = "a3d7f0c2b915"
down_revision: Union[str, Sequence[str], None] = "f1a9c2d38e64"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

DEFAULT_TENANT_ID = "00000000-0000-0000-0000-000000000001"


def upgrade() -> None:
    op.create_table(
        "plans",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column(
            "tenant_id",
            UUID(as_uuid=True),
            sa.ForeignKey("tenants.id", ondelete="CASCADE"),
            nullable=False,
            server_default=sa.text(f"'{DEFAULT_TENANT_ID}'"),
        ),
        sa.Column("prefix", sa.String(), nullable=False),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False, server_default="1"),
        sa.Column("source_format", sa.String(), nullable=False),
        sa.Column("source_text", sa.Text(), nullable=False),
        sa.Column("body", JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("source_hash", sa.String(), nullable=False),
        sa.Column("content_hash", sa.String(), nullable=False),
        sa.Column("created_by", sa.String(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("tenant_id", "prefix", "name", "version", name="uq_plans_tenant_prefix_name_version"),
        sa.CheckConstraint("prefix IN ('ansible', 'salt', 'puppet', 'chef')", name="ck_plans_prefix"),
    )
    op.create_index("idx_plans_lookup", "plans", ["tenant_id", "prefix", "name", "version"])


def downgrade() -> None:
    op.drop_index("idx_plans_lookup", table_name="plans")
    op.drop_table("plans")
