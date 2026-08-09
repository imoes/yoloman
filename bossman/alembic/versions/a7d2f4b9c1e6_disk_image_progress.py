"""disk_images: import/capture progress display string

Revision ID: a7d2f4b9c1e6
Revises: f5c3d9a1e7b4
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "a7d2f4b9c1e6"
down_revision = "f5c3d9a1e7b4"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("disk_images", sa.Column("progress", sa.String(), nullable=False, server_default=""))


def downgrade() -> None:
    op.drop_column("disk_images", "progress")
