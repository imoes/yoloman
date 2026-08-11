"""blueprint path (tree organisation)

Revision ID: b8d4f2a1c093
Revises: a7c3e9f10b21
Create Date: 2026-08-11 10:30:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'b8d4f2a1c093'
down_revision: Union[str, Sequence[str], None] = 'a7c3e9f10b21'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('blueprints', sa.Column('path', sa.String(), nullable=False, server_default=''))


def downgrade() -> None:
    op.drop_column('blueprints', 'path')
