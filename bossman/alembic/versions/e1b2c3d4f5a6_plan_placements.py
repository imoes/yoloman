"""plan_placements: plan-library directory tree (ltree)

Revision ID: e1b2c3d4f5a6
Revises: c9f1a2b3d4e5
Create Date: 2026-07-12

Where each logical plan/role (prefix+name) sits in the plan-library folder
tree. One row per logical plan; `folder` is the human path, `ltree_path` the
sanitized ltree (mirrors ou_nodes). Additive.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = "e1b2c3d4f5a6"
down_revision: Union[str, Sequence[str], None] = "c9f1a2b3d4e5"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute("CREATE EXTENSION IF NOT EXISTS ltree")
    op.create_table(
        "plan_placements",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column(
            "tenant_id", UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False,
            server_default=sa.text("'00000000-0000-0000-0000-000000000001'"),
        ),
        sa.Column("prefix", sa.String(), nullable=False),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("folder", sa.String(), nullable=False, server_default=""),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("tenant_id", "prefix", "name", name="uq_plan_placements_plan"),
    )
    # ltree column via raw SQL (SQLAlchemy has no native ltree type here).
    op.execute("ALTER TABLE plan_placements ADD COLUMN ltree_path ltree NOT NULL DEFAULT 'root'")
    op.execute("ALTER TABLE plan_placements ALTER COLUMN ltree_path DROP DEFAULT")
    op.create_index("idx_plan_placements_lookup", "plan_placements", ["tenant_id", "prefix", "name"])
    op.create_index("idx_plan_placements_ltree", "plan_placements", ["ltree_path"], postgresql_using="gist")


def downgrade() -> None:
    op.drop_index("idx_plan_placements_ltree", table_name="plan_placements")
    op.drop_index("idx_plan_placements_lookup", table_name="plan_placements")
    op.drop_table("plan_placements")
