"""soft/hard states + max attempts + flapping (Block H7)

Revision ID: d5f9b2c7a801
Revises: c4e8a1d5f6b2
Create Date: 2026-07-07

CheckMK-style state debouncing: a non-OK result is a *soft* state until it
has recurred `max_attempts` times, then *hard* — only hard non-OK states
count as problems / drive notifications. Plus a flapping flag for services
that oscillate too often. Existing rows default to hard/attempt 1 so they
stay problems exactly as before the migration.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "d5f9b2c7a801"
down_revision: Union[str, Sequence[str], None] = "c4e8a1d5f6b2"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("services", sa.Column("state_type", sa.String(), nullable=False, server_default="hard"))
    op.add_column("services", sa.Column("attempt", sa.Integer(), nullable=False, server_default="1"))
    op.add_column("services", sa.Column("max_attempts", sa.Integer(), nullable=False, server_default="3"))
    op.add_column("services", sa.Column("is_flapping", sa.Boolean(), nullable=False, server_default=sa.false()))
    op.create_check_constraint("ck_services_state_type", "services", "state_type IN ('soft', 'hard')")
    # Per-rule override of the global max-attempts default.
    op.add_column("check_rules", sa.Column("max_attempts", sa.Integer(), nullable=True))


def downgrade() -> None:
    op.drop_column("check_rules", "max_attempts")
    op.drop_constraint("ck_services_state_type", "services", type_="check")
    op.drop_column("services", "is_flapping")
    op.drop_column("services", "max_attempts")
    op.drop_column("services", "attempt")
    op.drop_column("services", "state_type")
