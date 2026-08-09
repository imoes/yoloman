"""timed acknowledgement expiry (Block H5)

Revision ID: b7d2f4a19c33
Revises: a3c1e9f04711
Create Date: 2026-07-07

CheckMK's "acknowledge for a limited time": an acknowledgement can carry
an expiry timestamp; once passed, the ack lapses and the problem
resurfaces. NULL = the existing indefinite acknowledgement.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "b7d2f4a19c33"
down_revision: Union[str, Sequence[str], None] = "a3c1e9f04711"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("services", sa.Column("ack_expires_at", sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    op.drop_column("services", "ack_expires_at")
