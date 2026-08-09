"""agent poll cursors

Revision ID: 8ddf50da59f5
Revises: f17d664762b0
Create Date: 2026-07-04 19:20:01.065721

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '8ddf50da59f5'
down_revision: Union[str, Sequence[str], None] = 'f17d664762b0'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.add_column('agents', sa.Column('last_metrics_pulled_at', sa.DateTime(timezone=True), nullable=True))
    op.add_column('agents', sa.Column('last_edges_pulled_at', sa.DateTime(timezone=True), nullable=True))
    # Autogenerate also proposed dropping connection_events_time_idx and
    # metrics_time_idx — deliberately NOT applied. Those are TimescaleDB's
    # own indexes, auto-created by create_hypertable() in the initial
    # migration and invisible to SQLAlchemy's model introspection, which is
    # exactly why autogenerate misreads them as "removed". Dropping them
    # would degrade every time-range query against both hypertables.


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_column('agents', 'last_edges_pulled_at')
    op.drop_column('agents', 'last_metrics_pulled_at')
