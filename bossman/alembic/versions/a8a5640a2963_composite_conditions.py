"""check_rules composite conditions — multi-metric AND/OR (Block K9)

Revision ID: a8a5640a2963
Revises: 3fe9ac195936
Create Date: 2026-07-07

Zabbix gap-analysis Block K9: a scoped v1 of Zabbix's multi-item boolean
trigger expressions. A rule can list extra_conditions (other metrics, same
host, each with its own comparison/warn/crit) combined with the primary
condition via condition_logic (AND/OR) — e.g. "CPU > 80 AND load1 > 4".
Deliberately same-host only (not cross-host correlation, which is a much
larger step — see docs/zabbix-gap-analysis.md's Batch 3).
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB

revision: str = "a8a5640a2963"
down_revision: Union[str, Sequence[str], None] = "3fe9ac195936"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("check_rules", sa.Column("extra_conditions", JSONB(astext_type=sa.Text()), nullable=True))
    op.add_column(
        "check_rules", sa.Column("condition_logic", sa.String(), nullable=False, server_default="AND")
    )
    op.create_check_constraint(
        "ck_check_rules_condition_logic", "check_rules", "condition_logic IN ('AND', 'OR')"
    )


def downgrade() -> None:
    op.drop_constraint("ck_check_rules_condition_logic", "check_rules", type_="check")
    op.drop_column("check_rules", "condition_logic")
    op.drop_column("check_rules", "extra_conditions")
