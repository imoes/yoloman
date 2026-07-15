"""config_policies: add host-group scope (K4 group scope)

A config policy can now be scoped to a host group (host_group_id) as well as an
OU (scope_ou_id). Exactly one is set; GPO order host > OU > group.

Revision ID: a3b4c5d6e7f8
Revises: f2a3b4c5d6e7
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision = "a3b4c5d6e7f8"
down_revision = "f2a3b4c5d6e7"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.alter_column("config_policies", "scope_ou_id", existing_type=UUID(as_uuid=True), nullable=True)
    op.add_column("config_policies", sa.Column("host_group_id", UUID(as_uuid=True), nullable=True))
    op.create_foreign_key(
        "fk_config_policies_group", "config_policies", "host_groups", ["host_group_id"], ["id"], ondelete="CASCADE"
    )
    op.create_unique_constraint("uq_config_policies_group_path", "config_policies", ["host_group_id", "path"])
    op.create_index("idx_config_policies_group", "config_policies", ["host_group_id"])


def downgrade() -> None:
    op.drop_index("idx_config_policies_group", table_name="config_policies")
    op.drop_constraint("uq_config_policies_group_path", "config_policies", type_="unique")
    op.drop_constraint("fk_config_policies_group", "config_policies", type_="foreignkey")
    op.drop_column("config_policies", "host_group_id")
    op.alter_column("config_policies", "scope_ou_id", existing_type=UUID(as_uuid=True), nullable=False)
