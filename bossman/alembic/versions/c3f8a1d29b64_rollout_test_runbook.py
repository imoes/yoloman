"""rollouts: optional functional-test runbook (post-upgrade verification)

An OU/group-driven upgrade rollout can name a functional-test runbook (an
Ansible-style playbook, AI-authorable) run after the upgrade on each wave; the
wave only passes the health gate if the test succeeds. Nullable — existing
rollouts gate on service health only, unchanged.

Revision ID: c3f8a1d29b64
Revises: b1e7c2a9f3d0
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "c3f8a1d29b64"
down_revision = "b1e7c2a9f3d0"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("rollouts", sa.Column("test_runbook_name", sa.String(), nullable=True))


def downgrade() -> None:
    op.drop_column("rollouts", "test_runbook_name")
