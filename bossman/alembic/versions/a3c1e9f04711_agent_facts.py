"""agent facts (HW/SW inventory, Block H2)

Revision ID: a3c1e9f04711
Revises: fd4f41b40434
Create Date: 2026-07-07

The agent's inventory document (internal/inventory, Block H1) arrives on
every hosts/overview poll; `facts` stores the latest one per host and
`facts_updated_at` records when it last changed hands — the CheckMK-style
"HW/SW inventory" persistence the UI's Inventory tab reads.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB

revision: str = "a3c1e9f04711"
down_revision: Union[str, Sequence[str], None] = "fd4f41b40434"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("agents", sa.Column("facts", JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")))
    op.add_column("agents", sa.Column("facts_updated_at", sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    op.drop_column("agents", "facts_updated_at")
    op.drop_column("agents", "facts")
