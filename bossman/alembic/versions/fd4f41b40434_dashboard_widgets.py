"""dashboard widgets

Revision ID: fd4f41b40434
Revises: 7bd8fbf091a8
Create Date: 2026-07-06 09:03:42.913551

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

# revision identifiers, used by Alembic.
revision: str = 'fd4f41b40434'
down_revision: Union[str, Sequence[str], None] = '7bd8fbf091a8'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table('dashboard_widgets',
    sa.Column('id', sa.UUID(), server_default=sa.text('gen_random_uuid()'), nullable=False),
    sa.Column('username', sa.String(), nullable=False),
    sa.Column('widget_type', sa.String(), nullable=False),
    sa.Column('title', sa.String(), nullable=False),
    sa.Column('gs_x', sa.Integer(), nullable=False),
    sa.Column('gs_y', sa.Integer(), nullable=False),
    sa.Column('gs_w', sa.Integer(), nullable=False),
    sa.Column('gs_h', sa.Integer(), nullable=False),
    sa.Column('config', postgresql.JSONB(astext_type=sa.Text()), nullable=False),
    sa.Column('pinned', sa.Boolean(), nullable=False),
    sa.Column('hidden', sa.Boolean(), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.CheckConstraint("widget_type IN ('top_hosts', 'problems', 'gauge', 'timeseries', 'donut', 'stat')", name='ck_dashboard_widgets_type'),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index('idx_dashboard_widgets_username', 'dashboard_widgets', ['username'], unique=False)
    # Autogenerate also proposed dropping idx_chunk_embeddings_hnsw_cosine,
    # connection_events_time_idx, metrics_time_idx,
    # idx_plan_embeddings_hnsw_cosine, and service_state_history_time_idx —
    # deliberately NOT applied. These are TimescaleDB's own hypertable
    # indexes and pgvector's HNSW indexes, both created via raw SQL in
    # earlier migrations and invisible to SQLAlchemy's model-based
    # diffing (the same recurring false positive documented in every
    # prior migration in this project).


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_index('idx_dashboard_widgets_username', table_name='dashboard_widgets')
    op.drop_table('dashboard_widgets')
