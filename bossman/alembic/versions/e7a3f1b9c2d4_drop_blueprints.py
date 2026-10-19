"""drop the blueprints table (the blueprint designer was removed)

The compose/stack blueprint designer feature was removed from the product. Its table `blueprints` is no longer read
or written by any code, so it is dropped here. The independent DB-credential provisioning that used to share the
blueprints API path survives, rehomed at /api/v1/provision/database — it never used this table.

downgrade recreates the table as it stood after f1a9c4d70e83 + the `path` column from b8d4f2a1c093.

Revision ID: e7a3f1b9c2d4
Revises: d4a8b2c6e9f1
Create Date: 2026-10-18

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "e7a3f1b9c2d4"
down_revision: Union[str, Sequence[str], None] = "d4a8b2c6e9f1"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.drop_table("blueprints")


def downgrade() -> None:
    op.create_table(
        "blueprints",
        sa.Column("id", postgresql.UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("tenant_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("description", sa.Text(), nullable=False, server_default=""),
        sa.Column("status", sa.String(), nullable=False, server_default="draft"),
        sa.Column("path", sa.String(), nullable=False, server_default=""),
        sa.Column("services", postgresql.JSONB(astext_type=sa.Text()), nullable=False, server_default=sa.text("'[]'::jsonb")),
        sa.Column("created_by", sa.String(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("tenant_id", "name", name="uq_blueprints_name"),
    )
