"""check assignments: assign checks to host/group/OU (Block G9-P2)

Revision ID: a1c4e7b2f309
Revises: f7c2d8b90a41
Create Date: 2026-07-10

A check (checks.d/<check_name>) assigned to a scope with per-scope
parameters/thresholds; a host's effective checks resolve GPO-style
(host > group > OU). Additive.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision: str = "a1c4e7b2f309"
down_revision: Union[str, Sequence[str], None] = "f7c2d8b90a41"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "check_assignments",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("tenant_id", UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False),
        sa.Column("check_name", sa.String(), nullable=False),
        sa.Column("scope_type", sa.String(), nullable=False),
        sa.Column("ou_id", UUID(as_uuid=True), sa.ForeignKey("ou_nodes.id", ondelete="CASCADE"), nullable=True),
        sa.Column("agent_id", UUID(as_uuid=True), sa.ForeignKey("agents.id", ondelete="CASCADE"), nullable=True),
        sa.Column("host_group_id", UUID(as_uuid=True), sa.ForeignKey("host_groups.id", ondelete="CASCADE"), nullable=True),
        sa.Column("parameters", JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("enabled", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("source", sa.String(), nullable=False, server_default="manual"),
        sa.Column("created_by", sa.String(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.CheckConstraint("scope_type IN ('ou', 'group', 'host')", name="ck_check_assignments_scope_type"),
    )
    op.create_index("idx_check_assignments_agent", "check_assignments", ["agent_id"])
    op.create_index("idx_check_assignments_group", "check_assignments", ["host_group_id"])
    op.create_index("idx_check_assignments_ou", "check_assignments", ["ou_id"])
    op.create_index("idx_check_assignments_check", "check_assignments", ["check_name"])


def downgrade() -> None:
    for idx in ("check", "ou", "group", "agent"):
        op.drop_index(f"idx_check_assignments_{idx}", table_name="check_assignments")
    op.drop_table("check_assignments")
