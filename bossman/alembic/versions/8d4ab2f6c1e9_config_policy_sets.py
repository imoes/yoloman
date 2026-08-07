"""config_policy_sets: named policy containers with multiple entries

A named Policy (GPMC "GPO") groups several config entries (config_policies rows)
under one name and links to one scope as a unit. Adds the container table and a
set_id FK on config_policies (the entries). Nullable/additive → existing per-path
policies are unaffected (set_id null = a bare entry).

Revision ID: 8d4ab2f6c1e9
Revises: 7c39a1e5b8d2
Create Date: 2026-08-07
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "8d4ab2f6c1e9"
down_revision: Union[str, Sequence[str], None] = "7c39a1e5b8d2"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "config_policy_sets",
        sa.Column("id", sa.UUID(), server_default=sa.text("gen_random_uuid()"), nullable=False),
        sa.Column("tenant_id", sa.UUID(), nullable=False),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("description", sa.Text(), nullable=True),
        sa.Column("scope_ou_id", sa.UUID(), nullable=True),
        sa.Column("host_group_id", sa.UUID(), nullable=True),
        sa.Column("site_id", sa.UUID(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.ForeignKeyConstraint(["scope_ou_id"], ["ou_nodes.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["host_group_id"], ["host_groups.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["site_id"], ["sites.id"], ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("tenant_id", "name", name="uq_config_policy_sets_tenant_name"),
    )
    op.add_column("config_policies", sa.Column("set_id", sa.UUID(), nullable=True))
    op.create_foreign_key(
        "fk_config_policies_set_id", "config_policies", "config_policy_sets",
        ["set_id"], ["id"], ondelete="CASCADE",
    )
    op.create_index("idx_config_policies_set", "config_policies", ["set_id"])


def downgrade() -> None:
    op.drop_index("idx_config_policies_set", table_name="config_policies")
    op.drop_constraint("fk_config_policies_set_id", "config_policies", type_="foreignkey")
    op.drop_column("config_policies", "set_id")
    op.drop_table("config_policy_sets")
