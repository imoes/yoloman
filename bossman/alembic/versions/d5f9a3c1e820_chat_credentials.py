"""chat preferences: per-user console settings (Block K)

Revision ID: d5f9a3c1e820
Revises: c4e8f1a2b7d0
Create Date: 2026-07-10

Per-user chat console settings (default backend + per-backend model). The
backends' OAuth tokens live in each user's bind-mounted home dir (the CLIs
manage them natively), not the DB — so only the settings are persisted here.
Additive.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision: str = "d5f9a3c1e820"
down_revision: Union[str, Sequence[str], None] = "c4e8f1a2b7d0"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "chat_preferences",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("username", sa.String(), nullable=False, unique=True),
        sa.Column("default_backend", sa.String(), nullable=False, server_default="claude_cli"),
        sa.Column("models", JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )


def downgrade() -> None:
    op.drop_table("chat_preferences")
