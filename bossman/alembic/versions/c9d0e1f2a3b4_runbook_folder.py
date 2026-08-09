"""runbooks.folder — library folder path for the runbook editor's tree

Mirrors the plan library's folder organization so the runbook editor can show
the same directory tree.

Revision ID: c9d0e1f2a3b4
Revises: b8c9d0e1f2a3
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "c9d0e1f2a3b4"
down_revision = "b8c9d0e1f2a3"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("runbooks", sa.Column("folder", sa.String(), nullable=False, server_default=""))


def downgrade() -> None:
    op.drop_column("runbooks", "folder")
