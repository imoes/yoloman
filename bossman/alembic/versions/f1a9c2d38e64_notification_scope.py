"""notification rules: shared scope model (host/service/policy + ou)

Revision ID: f1a9c2d38e64
Revises: e7a2b6c04d19
Create Date: 2026-07-09

Block N (per-host/per-service rules + service/service-policy notifications).
Adds the shared scope columns to notification_rules so a notification can be
targeted at a specific host, a specific service on a host, or a policy — the
same scope vocabulary check_rules already use. Existing rows become
scope_type='global', except those already bound to an OU (ou_id set), which
are backfilled to scope_type='ou' to preserve intent. Additive, non-
destructive.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = "f1a9c2d38e64"
down_revision: Union[str, Sequence[str], None] = "e7a2b6c04d19"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "notification_rules",
        sa.Column("scope_type", sa.String(), nullable=False, server_default="global"),
    )
    op.add_column("notification_rules", sa.Column("scope_value", sa.String(), nullable=True))
    op.add_column("notification_rules", sa.Column("scope_service_name", sa.String(), nullable=True))
    op.add_column("notification_rules", sa.Column("scope_plan_id", UUID(as_uuid=True), nullable=True))
    op.create_foreign_key(
        "fk_notification_rules_scope_plan",
        "notification_rules",
        "orchestration_plans",
        ["scope_plan_id"],
        ["id"],
        ondelete="CASCADE",
    )
    op.create_check_constraint(
        "ck_notification_rules_scope_type",
        "notification_rules",
        "scope_type IN ('global', 'ou', 'group', 'host', 'service', 'policy')",
    )
    # Preserve the intent of rules already bound to an OU.
    op.execute("UPDATE notification_rules SET scope_type = 'ou' WHERE ou_id IS NOT NULL")


def downgrade() -> None:
    op.drop_constraint("ck_notification_rules_scope_type", "notification_rules", type_="check")
    op.drop_constraint("fk_notification_rules_scope_plan", "notification_rules", type_="foreignkey")
    op.drop_column("notification_rules", "scope_plan_id")
    op.drop_column("notification_rules", "scope_service_name")
    op.drop_column("notification_rules", "scope_value")
    op.drop_column("notification_rules", "scope_type")
