"""runbooks: NestedText runbooks/roles stored as canonical JSON (Block G11)

Revision ID: b2d5f8a1c3e7
Revises: a1c4e7b2f309
Create Date: 2026-07-10

Runbooks live in the DB as JSON (doc); NestedText is the authoring form,
converted by services/nt_convert. Modules/checks stay on the filesystem.
Additive.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision: str = "b2d5f8a1c3e7"
down_revision: Union[str, Sequence[str], None] = "a1c4e7b2f309"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "runbooks",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("tenant_id", UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("kind", sa.String(), nullable=False, server_default="runbook"),
        sa.Column("doc", JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("created_by", sa.String(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("tenant_id", "name", name="uq_runbooks_tenant_name"),
        sa.CheckConstraint("kind IN ('runbook', 'role')", name="ck_runbooks_kind"),
    )


def downgrade() -> None:
    op.drop_table("runbooks")
