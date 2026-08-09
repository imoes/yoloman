"""run_retention_days on system_settings

Event/run history retention (days) for housekeeping to prune runbook_runs +
audit_log. Operator-set from the Admin settings UI. 0 = keep forever.

Revision ID: a2f4c6d8e0b1
Revises: f1a9c4d70e83
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "a2f4c6d8e0b1"
down_revision = "f1a9c4d70e83"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "system_settings",
        sa.Column("run_retention_days", sa.Integer(), nullable=False, server_default="90"),
    )


def downgrade() -> None:
    op.drop_column("system_settings", "run_retention_days")
