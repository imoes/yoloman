"""chat console: sessions + messages (Block K)

Revision ID: c4e8f1a2b7d0
Revises: a3d7f0c2b915
Create Date: 2026-07-10

The docked AI chat console persists conversations. chat_sessions is keyed by
username (like dashboard_widgets) and records the selected backend
(claude_cli/codex/hermes_web); chat_messages are its ordered {role, content}
turns with a JSONB meta for tool calls / emitted widget specs. Additive.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision: str = "c4e8f1a2b7d0"
down_revision: Union[str, Sequence[str], None] = "a3d7f0c2b915"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "chat_sessions",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("username", sa.String(), nullable=False),
        sa.Column("label", sa.String(), nullable=True),
        sa.Column("backend", sa.String(), nullable=False, server_default="claude_cli"),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index("idx_chat_sessions_username", "chat_sessions", ["username"])

    op.create_table(
        "chat_messages",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("session_id", UUID(as_uuid=True), sa.ForeignKey("chat_sessions.id", ondelete="CASCADE"), nullable=False),
        sa.Column("seq", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("role", sa.String(), nullable=False),
        sa.Column("content", sa.String(), nullable=False, server_default=""),
        sa.Column("meta", JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index("idx_chat_messages_session", "chat_messages", ["session_id", "seq"])


def downgrade() -> None:
    op.drop_index("idx_chat_messages_session", table_name="chat_messages")
    op.drop_table("chat_messages")
    op.drop_index("idx_chat_sessions_username", table_name="chat_sessions")
    op.drop_table("chat_sessions")
