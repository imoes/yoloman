"""restore_jobs.grow_mode — a deployment's own volume sizing.

The provisioning wizard used to write its sizing into the image (PATCH /images/{id}), so one deployment changed
the default for every later one. deploy() now arms the sizing on the job: grow_mode set means grow_policy is the
deployment's own and check-in keeps it; NULL means "take the image's", as before.

Revision ID: f2c8d4a6b1e3
Revises: e7a3f1b9c2d4
Create Date: 2026-10-18
"""

from alembic import op
import sqlalchemy as sa

revision = "f2c8d4a6b1e3"
down_revision = "e7a3f1b9c2d4"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("restore_jobs", sa.Column("grow_mode", sa.String(), nullable=True))


def downgrade() -> None:
    op.drop_column("restore_jobs", "grow_mode")
