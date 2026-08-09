"""runbook_runs: audit trail of runbook executions (Block G11)

Revision ID: c3e8f2b6d1a9
Revises: b2d5f8a1c3e7
Create Date: 2026-07-10

One row per runbook run against a host (dry-run or apply), with the engine's
RunResult as JSONB. Additive.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision: str = "c3e8f2b6d1a9"
down_revision: Union[str, Sequence[str], None] = "b2d5f8a1c3e7"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "runbook_runs",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("tenant_id", UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False),
        sa.Column("runbook_name", sa.String(), nullable=False),
        sa.Column("agent_id", UUID(as_uuid=True), sa.ForeignKey("agents.id", ondelete="SET NULL"), nullable=True),
        sa.Column("dry_run", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("status", sa.String(), nullable=False, server_default="ok"),
        sa.Column("changed", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("result", JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("requested_by", sa.String(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index("idx_runbook_runs_agent", "runbook_runs", ["agent_id"])


def downgrade() -> None:
    op.drop_index("idx_runbook_runs_agent", table_name="runbook_runs")
    op.drop_table("runbook_runs")
