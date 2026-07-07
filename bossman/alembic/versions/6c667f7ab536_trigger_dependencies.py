"""check_rules.depends_on_service_name — trigger dependencies (Block K8)

Revision ID: 6c667f7ab536
Revises: fd3dbebb1745
Create Date: 2026-07-07

Zabbix gap-analysis Block K8: one trigger can depend on another so a
"symptom" problem doesn't page anyone while its "root cause" is already a
confirmed problem on the same host — Zabbix's own trigger dependencies,
scoped here to same-host, name-based (not a full dependency graph).
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "6c667f7ab536"
down_revision: Union[str, Sequence[str], None] = "fd3dbebb1745"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("check_rules", sa.Column("depends_on_service_name", sa.String(), nullable=True))


def downgrade() -> None:
    op.drop_column("check_rules", "depends_on_service_name")
