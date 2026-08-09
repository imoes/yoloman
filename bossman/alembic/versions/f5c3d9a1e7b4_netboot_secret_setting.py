"""system_settings: WebUI-managed netboot secret + enable toggle

Revision ID: f5c3d9a1e7b4
Revises: e4b2c1d8f6a3
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "f5c3d9a1e7b4"
down_revision = "e4b2c1d8f6a3"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("system_settings", sa.Column("netboot_enabled", sa.Boolean(), nullable=False, server_default="false"))
    op.add_column("system_settings", sa.Column("netboot_secret", sa.String(), nullable=False, server_default=""))


def downgrade() -> None:
    op.drop_column("system_settings", "netboot_secret")
    op.drop_column("system_settings", "netboot_enabled")
