"""chunk embeddings translated json

Revision ID: f095218bdf99
Revises: bd020d926560
Create Date: 2026-07-05 14:29:46.174406

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'f095218bdf99'
down_revision: Union[str, Sequence[str], None] = 'bd020d926560'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    # Nullable: existing rows (indexed the older, source-text-only way,
    # or any future row indexed by a human without a real translation to
    # attach) simply have no reuse-reconstruction content — they still
    # participate in similarity search on source_text/embedding.
    op.add_column('chunk_embeddings', sa.Column('translated_json', sa.Text(), nullable=True))


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_column('chunk_embeddings', 'translated_json')
