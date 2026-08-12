"""remediation autonomy (Phase 2): autonomy + guardrails

Revision ID: d1f6a83b9e42
Revises: c9e1b47a2d05
Create Date: 2026-08-12 11:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'd1f6a83b9e42'
down_revision: Union[str, Sequence[str], None] = 'c9e1b47a2d05'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('remediation_policies', sa.Column('autonomy', sa.String(), nullable=False, server_default='propose'))
    op.add_column('remediation_policies', sa.Column('allow_prod', sa.Boolean(), nullable=False, server_default='false'))
    op.add_column('remediation_policies', sa.Column('max_blast_radius', sa.Integer(), nullable=False, server_default='1'))
    op.add_column('remediation_policies', sa.Column('rollback_runbook', sa.String(), nullable=True))


def downgrade() -> None:
    for col in ('rollback_runbook', 'max_blast_radius', 'allow_prod', 'autonomy'):
        op.drop_column('remediation_policies', col)
