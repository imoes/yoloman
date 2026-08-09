"""host tags + notification tag filter (Block K7)

Revision ID: fd3dbebb1745
Revises: fa0b5a906c25
Create Date: 2026-07-07

Zabbix gap-analysis Block K7: host-level tags (name or name:value),
inherited onto problems for filtering (GET /api/v1/problems?tag=) and used
to route notifications (NotificationRule.tag_filter) — the foundational
slice of Zabbix's tagging system (event correlation and per-tag RBAC
scoping are deferred, noted in docs/zabbix-gap-analysis.md's Batch 3).
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB

revision: str = "fd3dbebb1745"
down_revision: Union[str, Sequence[str], None] = "fa0b5a906c25"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("agents", sa.Column("tags", JSONB(astext_type=sa.Text()), nullable=False, server_default="{}"))
    op.add_column(
        "notification_rules", sa.Column("tag_filter", JSONB(astext_type=sa.Text()), nullable=True)
    )


def downgrade() -> None:
    op.drop_column("notification_rules", "tag_filter")
    op.drop_column("agents", "tags")
