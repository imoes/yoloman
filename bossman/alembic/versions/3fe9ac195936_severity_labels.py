"""severity_labels — custom severity names/colors (Block K10)

Revision ID: 3fe9ac195936
Revises: 6c667f7ab536
Create Date: 2026-07-07

Zabbix gap-analysis Block K10: display-only label/color override per
state. Deliberately cosmetic — yolo-man's 4-state model (OK/WARN/CRIT/
UNKNOWN) stays the real state machine; this only renames/recolors how a
state is *shown*, unlike Zabbix's 6 free-text severities which are the
actual trigger severity values.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "3fe9ac195936"
down_revision: Union[str, Sequence[str], None] = "6c667f7ab536"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

_DEFAULTS = [
    ("OK", "OK", "#1e9600"),
    ("WARN", "WARN", "#ffc800"),
    ("CRIT", "CRIT", "#d0021b"),
    ("UNKNOWN", "UNKNOWN", "#8a8a8a"),
]


def upgrade() -> None:
    op.create_table(
        "severity_labels",
        sa.Column("state", sa.String(), nullable=False),
        sa.Column("label", sa.String(), nullable=False),
        sa.Column("color", sa.String(), nullable=False),
        sa.PrimaryKeyConstraint("state"),
        sa.CheckConstraint("state IN ('OK', 'WARN', 'CRIT', 'UNKNOWN')", name="ck_severity_labels_state"),
    )
    table = sa.table("severity_labels", sa.column("state"), sa.column("label"), sa.column("color"))
    op.bulk_insert(table, [{"state": s, "label": lbl, "color": c} for s, lbl, c in _DEFAULTS])


def downgrade() -> None:
    op.drop_table("severity_labels")
