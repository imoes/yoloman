"""events — Event Console (syslog + SNMP traps)

Revision ID: d3e4f5a6b7c8
Revises: c2d3e4f5a6b7
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision = "d3e4f5a6b7c8"
down_revision = "c2d3e4f5a6b7"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "events",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("received_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("kind", sa.String(), nullable=False),
        sa.Column("source_ip", sa.String(), nullable=False),
        sa.Column("host_name", sa.String(), nullable=True),
        sa.Column("severity", sa.Integer(), nullable=False, server_default="6"),
        sa.Column("facility", sa.Integer(), nullable=True),
        sa.Column("app", sa.String(), nullable=True),
        sa.Column("message", sa.Text(), nullable=False, server_default=""),
        sa.Column("acknowledged", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("raw", sa.Text(), nullable=True),
    )
    op.create_index("idx_events_received", "events", ["received_at"])
    op.create_index("idx_events_host", "events", ["host_name"])


def downgrade() -> None:
    op.drop_index("idx_events_host", table_name="events")
    op.drop_index("idx_events_received", table_name="events")
    op.drop_table("events")
