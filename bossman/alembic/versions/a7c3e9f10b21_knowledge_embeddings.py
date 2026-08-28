"""knowledge embeddings (infra-grounded RAG)

Revision ID: a7c3e9f10b21
Revises: d5f7a9c1e3b4
Create Date: 2026-08-10 20:20:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from pgvector.sqlalchemy import Vector


# revision identifiers, used by Alembic.
revision: str = 'a7c3e9f10b21'
down_revision: Union[str, Sequence[str], None] = 'd5f7a9c1e3b4'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

# Must match db.models.CHUNK_EMBEDDING_DIM (bge-m3's output dimension).
KNOWLEDGE_EMBEDDING_DIM = 1024


def upgrade() -> None:
    """Upgrade schema."""
    # pgvector's type + HNSW index kind aren't autogenerate-able (same reason
    # chunk_embeddings/plan_embeddings are raw ops); the `vector` extension is
    # already enabled by an earlier migration.
    op.execute("CREATE EXTENSION IF NOT EXISTS vector")

    op.create_table(
        'knowledge_embeddings',
        sa.Column('doc_id', sa.String(), nullable=False),
        sa.Column('kind', sa.String(), nullable=False),
        sa.Column('ref_id', sa.String(), nullable=True),
        sa.Column('host_id', sa.UUID(), nullable=True),
        sa.Column('title', sa.String(), nullable=False),
        sa.Column('text', sa.Text(), nullable=False),
        sa.Column('content_hash', sa.String(), nullable=False),
        # Nullable: a card is stored even without an embedding model available
        # (lexical fallback still grounds the AI); the vector is an optimisation.
        sa.Column('embedding', Vector(KNOWLEDGE_EMBEDDING_DIM), nullable=True),
        sa.Column('model', sa.String(), nullable=False, server_default=''),
        sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.PrimaryKeyConstraint('doc_id'),
    )
    op.create_index('idx_knowledge_embeddings_host', 'knowledge_embeddings', ['host_id'])
    op.create_index('idx_knowledge_embeddings_kind', 'knowledge_embeddings', ['kind'])
    # HNSW + cosine: matches services/knowledge_search.py's
    # KnowledgeEmbedding.embedding.cosine_distance(...) query.
    op.execute(
        "CREATE INDEX idx_knowledge_embeddings_hnsw_cosine ON knowledge_embeddings "
        "USING hnsw (embedding vector_cosine_ops)"
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.execute("DROP INDEX IF EXISTS idx_knowledge_embeddings_hnsw_cosine")
    op.drop_index('idx_knowledge_embeddings_kind', table_name='knowledge_embeddings')
    op.drop_index('idx_knowledge_embeddings_host', table_name='knowledge_embeddings')
    op.drop_table('knowledge_embeddings')
    # The vector extension is deliberately NOT dropped (shared).
