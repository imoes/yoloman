"""notification channels + escalation

Widen notification_rules.channel beyond email/webhook to the common chat/paging
targets (slack, teams, telegram, pagerduty, discord), and add
escalate_after_minutes for on-call escalation chains: a rule with a value fires
only once a hard problem has stayed unacknowledged that many minutes (NULL =
fire immediately on the state-change event, today's behaviour).

Revision ID: b1c2d3e4f5a6
Revises: a3b4c5d6e7f8
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "b1c2d3e4f5a6"
down_revision = "a3b4c5d6e7f8"
branch_labels = None
depends_on = None

_CHANNELS = "('email', 'webhook', 'slack', 'teams', 'telegram', 'pagerduty', 'discord')"


def upgrade() -> None:
    op.drop_constraint("ck_notification_rules_channel", "notification_rules", type_="check")
    op.create_check_constraint("ck_notification_rules_channel", "notification_rules", f"channel IN {_CHANNELS}")
    op.add_column("notification_rules", sa.Column("escalate_after_minutes", sa.Integer(), nullable=True))


def downgrade() -> None:
    op.drop_column("notification_rules", "escalate_after_minutes")
    op.drop_constraint("ck_notification_rules_channel", "notification_rules", type_="check")
    op.create_check_constraint(
        "ck_notification_rules_channel", "notification_rules", "channel IN ('email', 'webhook')"
    )
