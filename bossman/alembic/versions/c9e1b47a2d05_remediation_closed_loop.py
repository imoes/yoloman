"""remediation closed-loop lifecycle (verify + phase)

Revision ID: c9e1b47a2d05
Revises: b8d4f2a1c093
Create Date: 2026-08-12 09:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'c9e1b47a2d05'
down_revision: Union[str, Sequence[str], None] = 'b8d4f2a1c093'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # remediation_runs → lifecycle/verify columns
    op.add_column('remediation_runs', sa.Column('phase', sa.String(), nullable=False, server_default='proposed'))
    op.add_column('remediation_runs', sa.Column('applied_at', sa.DateTime(timezone=True), nullable=True))
    op.add_column('remediation_runs', sa.Column('verify_due_at', sa.DateTime(timezone=True), nullable=True))
    op.add_column('remediation_runs', sa.Column('verified_at', sa.DateTime(timezone=True), nullable=True))
    op.add_column('remediation_runs', sa.Column('verify_state', sa.String(), nullable=True))
    op.add_column('remediation_runs', sa.Column('verify_ok', sa.Boolean(), nullable=True))
    op.add_column('remediation_runs', sa.Column('outcome', sa.Text(), nullable=True))
    op.create_index('idx_remediation_runs_verify', 'remediation_runs', ['phase', 'verify_due_at'])
    # Backfill phase from the coarse status so existing rows land in a sane state.
    op.execute("UPDATE remediation_runs SET phase = CASE "
               "WHEN status = 'pending' THEN 'proposed' "
               "WHEN status = 'ran' THEN 'resolved' "
               "WHEN status = 'failed' THEN 'failed' ELSE 'proposed' END")

    # remediation_policies → verify knobs
    op.add_column('remediation_policies', sa.Column('verify', sa.Boolean(), nullable=False, server_default='true'))
    op.add_column('remediation_policies', sa.Column('verify_after_s', sa.Integer(), nullable=False, server_default='60'))


def downgrade() -> None:
    op.drop_column('remediation_policies', 'verify_after_s')
    op.drop_column('remediation_policies', 'verify')
    op.drop_index('idx_remediation_runs_verify', table_name='remediation_runs')
    for col in ('outcome', 'verify_ok', 'verify_state', 'verified_at', 'verify_due_at', 'applied_at', 'phase'):
        op.drop_column('remediation_runs', col)
