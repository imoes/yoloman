"""agent criticality + site facets

Adds two first-class, queryable host facets used by the Checkmk-style fleet
search (crit:/site:) and assignable single/bulk from the UI. Additive and
nullable — existing rows keep NULL (unset) until assigned.

Revision ID: e2f3a4b5c6d7
Revises: d1e2f3a4b5c6
Create Date: 2026-07-21 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'e2f3a4b5c6d7'
down_revision: Union[str, Sequence[str], None] = 'd1e2f3a4b5c6'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('agents', sa.Column('criticality', sa.String(), nullable=True))
    op.add_column('agents', sa.Column('site', sa.String(), nullable=True))
    op.create_check_constraint(
        'ck_agents_criticality',
        'agents',
        "criticality IS NULL OR criticality IN ('test', 'stage', 'prod')",
    )
    op.create_index('idx_agents_criticality', 'agents', ['criticality'])
    op.create_index('idx_agents_site', 'agents', ['site'])


def downgrade() -> None:
    op.drop_index('idx_agents_site', table_name='agents')
    op.drop_index('idx_agents_criticality', table_name='agents')
    op.drop_constraint('ck_agents_criticality', 'agents', type_='check')
    op.drop_column('agents', 'site')
    op.drop_column('agents', 'criticality')
