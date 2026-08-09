"""chunk embeddings

Revision ID: 6bf60cdbd2f1
Revises: 8ddf50da59f5
Create Date: 2026-07-05 13:50:29.235602

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from pgvector.sqlalchemy import Vector


# revision identifiers, used by Alembic.
revision: str = '6bf60cdbd2f1'
down_revision: Union[str, Sequence[str], None] = '8ddf50da59f5'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

# Must match db.models.CHUNK_EMBEDDING_DIM (bge-m3's output dimension).
CHUNK_EMBEDDING_DIM = 1024


def upgrade() -> None:
    """Upgrade schema."""
    # Not expressible via autogenerate — pgvector's type and its own HNSW
    # index kind aren't things SQLAlchemy's reflection understands, same
    # reason the TimescaleDB hypertable/continuous-aggregate calls in the
    # initial migration are raw SQL too. Confirmed the `vector` extension
    # is already available (though not yet enabled) in the project's dev
    # database image before writing this — no image change needed.
    op.execute("CREATE EXTENSION IF NOT EXISTS vector")

    op.create_table(
        'chunk_embeddings',
        sa.Column('chunk_id', sa.String(), nullable=False),
        sa.Column('plan_name', sa.String(), nullable=False),
        sa.Column('chunk_name', sa.String(), nullable=False),
        sa.Column('source_hash', sa.String(), nullable=True),
        sa.Column('source_text', sa.Text(), nullable=False),
        sa.Column('embedding', Vector(CHUNK_EMBEDDING_DIM), nullable=False),
        sa.Column('model', sa.String(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.PrimaryKeyConstraint('chunk_id'),
    )

    # HNSW + cosine distance: matches how services/chunk_similarity.py
    # queries (ChunkEmbedding.embedding.cosine_distance(...)).
    op.execute(
        "CREATE INDEX idx_chunk_embeddings_hnsw_cosine ON chunk_embeddings "
        "USING hnsw (embedding vector_cosine_ops)"
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.execute("DROP INDEX IF EXISTS idx_chunk_embeddings_hnsw_cosine")
    op.drop_table('chunk_embeddings')
    # The vector extension is deliberately NOT dropped — like timescaledb
    # in the initial migration's own downgrade, dropping a shared extension
    # here could affect other objects outside this migration's scope.
