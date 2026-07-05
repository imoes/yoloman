"""plan embeddings

Revision ID: bd020d926560
Revises: 6bf60cdbd2f1
Create Date: 2026-07-05 14:29:45.922762

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from pgvector.sqlalchemy import Vector


# revision identifiers, used by Alembic.
revision: str = 'bd020d926560'
down_revision: Union[str, Sequence[str], None] = '6bf60cdbd2f1'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

# Must match db.models.CHUNK_EMBEDDING_DIM (bge-m3's output dimension) —
# same constant, same reasoning as the chunk_embeddings migration.
PLAN_EMBEDDING_DIM = 1024


def upgrade() -> None:
    """Upgrade schema."""
    # vector extension already enabled by the chunk_embeddings migration,
    # but IF NOT EXISTS makes this migration independently re-runnable.
    op.execute("CREATE EXTENSION IF NOT EXISTS vector")

    op.create_table(
        'plan_embeddings',
        sa.Column('name', sa.String(), nullable=False),
        sa.Column('description', sa.Text(), nullable=False),
        sa.Column('content_hash', sa.String(), nullable=False),
        sa.Column('embedding', Vector(PLAN_EMBEDDING_DIM), nullable=False),
        sa.Column('model', sa.String(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.PrimaryKeyConstraint('name'),
    )

    op.execute(
        "CREATE INDEX idx_plan_embeddings_hnsw_cosine ON plan_embeddings "
        "USING hnsw (embedding vector_cosine_ops)"
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.execute("DROP INDEX IF EXISTS idx_plan_embeddings_hnsw_cosine")
    op.drop_table('plan_embeddings')
    # vector extension deliberately not dropped, same reasoning as the
    # chunk_embeddings migration's own downgrade.
