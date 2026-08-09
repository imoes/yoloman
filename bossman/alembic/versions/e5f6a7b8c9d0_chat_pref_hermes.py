"""per-user console LLM endpoint config (hermes_base_url / hermes_model)

Lets the console's OpenAI-compatible (hermes) endpoint + model be configured
per user from Settings instead of being pinned in environment variables.

Revision ID: e5f6a7b8c9d0
Revises: d4a1b2c3e5f6
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "e5f6a7b8c9d0"
down_revision = "d4a1b2c3e5f6"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("chat_preferences", sa.Column("hermes_base_url", sa.String(), nullable=True))
    op.add_column("chat_preferences", sa.Column("hermes_model", sa.String(), nullable=True))


def downgrade() -> None:
    op.drop_column("chat_preferences", "hermes_model")
    op.drop_column("chat_preferences", "hermes_base_url")
