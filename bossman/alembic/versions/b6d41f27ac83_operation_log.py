"""operation_log — the fleet-wide result log

What was DONE to a host and what came back: module, outcome, the evidence (exit code, the -WhatIf plan, the
target's own refusal text), how long it took, who asked. The agent keeps a ring buffer and answers for itself
(GET /api/v1/audit); this table is the durable copy that makes a fleet-wide question one query and survives an
agent restart.

Deliberately NOT merged with the audit trail: that records what somebody asked this SERVER to do, this records
what a HOST actually did. A request and its effect are two facts, and only the second answers "did that
install work".

(agent_id, boot_id, seq) is unique — the agent's sequence numbers are monotonic within one process and
`boot_id` names the process, so re-collection is idempotent and a restart is unambiguous rather than a silent
gap.

Revision ID: b6d41f27ac83
Revises: a7c3e91d5b40
Create Date: 2026-08-27
"""

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = "b6d41f27ac83"
down_revision = "a7c3e91d5b40"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "operation_log",
        sa.Column("id", postgresql.UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"),
                  primary_key=True),
        sa.Column("agent_id", postgresql.UUID(as_uuid=True),
                  sa.ForeignKey("agents.id", ondelete="CASCADE"), nullable=False),
        sa.Column("boot_id", sa.String(), nullable=False),
        sa.Column("seq", sa.BigInteger(), nullable=False),
        sa.Column("record_id", sa.String()),
        sa.Column("module", sa.String(), nullable=False),
        sa.Column("outcome", sa.String(), nullable=False),
        sa.Column("dry_run", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("params", postgresql.JSONB()),
        sa.Column("identity", sa.String()),
        sa.Column("started_at", sa.DateTime(timezone=True)),
        sa.Column("duration_ms", sa.Float()),
        sa.Column("changed", sa.Boolean()),
        sa.Column("message", sa.String()),
        sa.Column("evidence", postgresql.JSONB()),
        sa.Column("error", sa.String()),
        sa.Column("collected_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("agent_id", "boot_id", "seq", name="uq_operation_log_agent_boot_seq"),
    )
    op.create_index("ix_operation_log_agent_id", "operation_log", ["agent_id"])
    op.create_index("ix_operation_log_module", "operation_log", ["module"])
    op.create_index("ix_operation_log_outcome", "operation_log", ["outcome"])
    # The one index the fleet-wide question actually uses: "what happened lately", newest first.
    op.create_index("ix_operation_log_started_at", "operation_log", [sa.text("started_at DESC")])


def downgrade() -> None:
    op.drop_index("ix_operation_log_started_at", table_name="operation_log")
    op.drop_index("ix_operation_log_outcome", table_name="operation_log")
    op.drop_index("ix_operation_log_module", table_name="operation_log")
    op.drop_index("ix_operation_log_agent_id", table_name="operation_log")
    op.drop_table("operation_log")
