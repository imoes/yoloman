"""check rule label_value + is_default (Block H6)

Revision ID: c4e8a1d5f6b2
Revises: b7d2f4a19c33
Create Date: 2026-07-07

Configurable thresholds with per-host override for individual services,
including the agent's built-in checks: a rule can pin a label value (a
disk mount) and can be flagged as a seeded default reproducing a former
hardcoded agent threshold.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "c4e8a1d5f6b2"
down_revision: Union[str, Sequence[str], None] = "b7d2f4a19c33"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("check_rules", sa.Column("label_value", sa.String(), nullable=True))
    op.add_column(
        "check_rules",
        sa.Column("is_default", sa.Boolean(), nullable=False, server_default=sa.false()),
    )


def downgrade() -> None:
    op.drop_column("check_rules", "is_default")
    op.drop_column("check_rules", "label_value")
