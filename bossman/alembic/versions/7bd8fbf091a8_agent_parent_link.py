"""agent parent link

Revision ID: 7bd8fbf091a8
Revises: 50e78cc78c2a
Create Date: 2026-07-06 08:14:08.394938

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '7bd8fbf091a8'
down_revision: Union[str, Sequence[str], None] = '50e78cc78c2a'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.add_column('agents', sa.Column('parent_agent_id', sa.UUID(), nullable=True))
    op.create_foreign_key('agents_parent_agent_id_fkey', 'agents', 'agents', ['parent_agent_id'], ['id'])
    # Autogenerate also proposed dropping idx_chunk_embeddings_hnsw_cosine,
    # connection_events_time_idx, metrics_time_idx,
    # idx_plan_embeddings_hnsw_cosine, and service_state_history_time_idx —
    # deliberately NOT applied. These are TimescaleDB's own hypertable
    # indexes and pgvector's HNSW indexes, both created via raw SQL in
    # earlier migrations and invisible to SQLAlchemy's model-based
    # diffing, which is exactly why autogenerate misreads them as
    # "removed" (the same recurring false positive documented in every
    # prior migration in this project).


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_constraint('agents_parent_agent_id_fkey', 'agents', type_='foreignkey')
    op.drop_column('agents', 'parent_agent_id')
