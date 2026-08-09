"""check_rules.recovery_threshold — hysteresis (Block K6)

Revision ID: fa0b5a906c25
Revises: 617ee650d292
Create Date: 2026-07-07

Zabbix gap-analysis Block K6: an optional, stricter threshold a problem
must cross before it's allowed to recover to OK — a deadband that stops a
value oscillating right around the warn threshold from flapping between
OK and WARN every poll (H7's max_attempts already debounces the onset
side; this is the missing recovery-side equivalent, Zabbix's separate
"recovery expression").
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "fa0b5a906c25"
down_revision: Union[str, Sequence[str], None] = "617ee650d292"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("check_rules", sa.Column("recovery_threshold", sa.Float(), nullable=True))


def downgrade() -> None:
    op.drop_column("check_rules", "recovery_threshold")
