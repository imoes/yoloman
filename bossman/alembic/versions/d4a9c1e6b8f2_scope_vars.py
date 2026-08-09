"""scope_vars: GPO-resolved variables per host/group/OU (Block G11)

Revision ID: d4a9c1e6b8f2
Revises: c3e8f2b6d1a9
Create Date: 2026-07-10

Variables attached to a host/group/OU, resolved GPO-style for runbook runs
(global < group < OU root→leaf < host). Additive.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision: str = "d4a9c1e6b8f2"
down_revision: Union[str, Sequence[str], None] = "c3e8f2b6d1a9"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "scope_vars",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("tenant_id", UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False),
        sa.Column("scope_type", sa.String(), nullable=False),
        sa.Column("ou_id", UUID(as_uuid=True), sa.ForeignKey("ou_nodes.id", ondelete="CASCADE"), nullable=True),
        sa.Column("agent_id", UUID(as_uuid=True), sa.ForeignKey("agents.id", ondelete="CASCADE"), nullable=True),
        sa.Column("host_group_id", UUID(as_uuid=True), sa.ForeignKey("host_groups.id", ondelete="CASCADE"), nullable=True),
        sa.Column("vars", JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.CheckConstraint("scope_type IN ('ou', 'group', 'host')", name="ck_scope_vars_scope_type"),
    )
    op.create_index("idx_scope_vars_ou", "scope_vars", ["ou_id"])
    op.create_index("idx_scope_vars_group", "scope_vars", ["host_group_id"])
    op.create_index("idx_scope_vars_agent", "scope_vars", ["agent_id"])


def downgrade() -> None:
    for idx in ("agent", "group", "ou"):
        op.drop_index(f"idx_scope_vars_{idx}", table_name="scope_vars")
    op.drop_table("scope_vars")
