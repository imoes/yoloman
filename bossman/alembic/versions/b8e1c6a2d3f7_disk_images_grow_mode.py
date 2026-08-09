"""disk_images: grow_mode (percent | absolute) for per-volume GiB sizing

The grow policy could only be percentages of the leftover space. grow_mode lets a template instead give
each volume an absolute size in GiB (a 0 meaning "fill the rest"). Default 'percent' keeps every existing
image behaving exactly as before.

Revision ID: b8e1c6a2d3f7
Revises: a7d2f4b9c1e6
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "b8e1c6a2d3f7"
down_revision = "a7d2f4b9c1e6"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "disk_images",
        sa.Column("grow_mode", sa.String(), nullable=False, server_default="percent"),
    )
    op.create_check_constraint(
        "ck_disk_images_grow_mode", "disk_images", "grow_mode IN ('percent', 'absolute')"
    )


def downgrade() -> None:
    op.drop_constraint("ck_disk_images_grow_mode", "disk_images", type_="check")
    op.drop_column("disk_images", "grow_mode")
