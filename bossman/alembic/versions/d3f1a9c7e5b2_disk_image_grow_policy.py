"""disk_images: active-template flag + grow policy (root/var/home percentages)

Revision ID: d3f1a9c7e5b2
Revises: a1c9e4f2b7d3
"""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB

revision = "d3f1a9c7e5b2"
down_revision = "a1c9e4f2b7d3"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("disk_images", sa.Column("is_active", sa.Boolean(), nullable=False, server_default=sa.false()))
    op.add_column("disk_images", sa.Column("grow_policy", JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")))
    op.add_column("restore_jobs", sa.Column("grow_policy", JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")))
    # At most one active template at a time.
    op.create_index("uq_disk_images_one_active", "disk_images", ["is_active"], unique=True,
                    postgresql_where=sa.text("is_active"))


def downgrade() -> None:
    op.drop_index("uq_disk_images_one_active", table_name="disk_images")
    op.drop_column("restore_jobs", "grow_policy")
    op.drop_column("disk_images", "grow_policy")
    op.drop_column("disk_images", "is_active")
