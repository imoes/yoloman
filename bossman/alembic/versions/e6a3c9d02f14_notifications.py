"""notification rules + log (Block H8)

Revision ID: e6a3c9d02f14
Revises: d5f9b2c7a801
Create Date: 2026-07-07

CheckMK-style notifications: rules decide who gets told (by channel) when
a service has a confirmed problem/recovery, and a log records every send.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = "e6a3c9d02f14"
down_revision: Union[str, Sequence[str], None] = "d5f9b2c7a801"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "notification_rules",
        sa.Column("id", UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("enabled", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("on_problem", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("on_recovery", sa.Boolean(), nullable=False, server_default=sa.true()),
        # Minimum severity that triggers: WARN|CRIT|UNKNOWN.
        sa.Column("min_state", sa.String(), nullable=False, server_default="WARN"),
        # Optional substring filters on host / service name (NULL = any).
        sa.Column("host_filter", sa.String(), nullable=True),
        sa.Column("service_filter", sa.String(), nullable=True),
        sa.Column("channel", sa.String(), nullable=False),  # email | webhook
        sa.Column("target", sa.String(), nullable=False),  # address(es) or URL
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.CheckConstraint("channel IN ('email', 'webhook')", name="ck_notification_rules_channel"),
        sa.CheckConstraint("min_state IN ('WARN', 'CRIT', 'UNKNOWN')", name="ck_notification_rules_min_state"),
    )
    op.create_table(
        "notifications",
        sa.Column("id", UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")),
        sa.Column("rule_id", UUID(as_uuid=True), sa.ForeignKey("notification_rules.id", ondelete="SET NULL"), nullable=True),
        sa.Column("agent_name", sa.String(), nullable=False),
        sa.Column("service_name", sa.String(), nullable=False),
        sa.Column("event", sa.String(), nullable=False),  # problem | recovery
        sa.Column("state", sa.String(), nullable=False),
        sa.Column("channel", sa.String(), nullable=False),
        sa.Column("target", sa.String(), nullable=False),
        sa.Column("status", sa.String(), nullable=False),  # sent | failed
        sa.Column("error", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.Index("idx_notifications_created", "created_at"),
    )


def downgrade() -> None:
    op.drop_table("notifications")
    op.drop_table("notification_rules")
