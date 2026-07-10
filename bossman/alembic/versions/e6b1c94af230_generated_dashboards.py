"""generated dashboards: per-user AI-designed dashboards (Block W2)

Revision ID: e6b1c94af230
Revises: d5f9a3c1e820
Create Date: 2026-07-10

One row per user holding the AI-generated widget-spec array (inline data), for
the generative dashboard. Additive.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision: str = "e6b1c94af230"
down_revision: Union[str, Sequence[str], None] = "d5f9a3c1e820"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "generated_dashboards",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("username", sa.String(), nullable=False, unique=True),
        sa.Column("prompt", sa.String(), nullable=False, server_default=""),
        sa.Column("widgets", JSONB(), nullable=False, server_default=sa.text("'[]'::jsonb")),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )


def downgrade() -> None:
    op.drop_table("generated_dashboards")
