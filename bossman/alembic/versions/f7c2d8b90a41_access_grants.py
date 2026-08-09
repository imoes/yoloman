"""access grants: per-subject host management ACL (Block M)

Revision ID: f7c2d8b90a41
Revises: e6b1c94af230
Create Date: 2026-07-10

Which users / API tokens may MANAGE which hosts or host groups. admin users
bypass; everyone else needs a grant. scope='all' is a wildcard. Additive.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = "f7c2d8b90a41"
down_revision: Union[str, Sequence[str], None] = "e6b1c94af230"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "access_grants",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("subject_kind", sa.String(), nullable=False),
        sa.Column("subject_ref", sa.String(), nullable=False),
        sa.Column("scope", sa.String(), nullable=False),
        sa.Column("agent_id", UUID(as_uuid=True), sa.ForeignKey("agents.id", ondelete="CASCADE"), nullable=True),
        sa.Column("host_group_id", UUID(as_uuid=True), sa.ForeignKey("host_groups.id", ondelete="CASCADE"), nullable=True),
        sa.Column("permission", sa.String(), nullable=False, server_default="manage"),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.CheckConstraint("subject_kind IN ('user', 'api_token')", name="ck_access_grants_subject_kind"),
        sa.CheckConstraint("scope IN ('all', 'host', 'host_group')", name="ck_access_grants_scope"),
    )
    op.create_index("idx_access_grants_subject", "access_grants", ["subject_kind", "subject_ref"])


def downgrade() -> None:
    op.drop_index("idx_access_grants_subject", table_name="access_grants")
    op.drop_table("access_grants")
