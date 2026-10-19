"""Diagnoses — why a service does not run, as the agents measured it (docs/diagnosis.md, plan B8).

Revision ID: b8d1a6c3e4f2
Revises: a9c4e2f7b1d3
Create Date: 2026-10-17
"""

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = "b8d1a6c3e4f2"
down_revision = "a9c4e2f7b1d3"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "diagnoses",
        sa.Column("id", postgresql.UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("tenant_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"),
                  nullable=False, server_default="00000000-0000-0000-0000-000000000001"),
        sa.Column("agent_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("agents.id", ondelete="CASCADE"), nullable=False),
        sa.Column("diagnosis_id", sa.String(), nullable=False),
        sa.Column("host", sa.String(), nullable=False),
        sa.Column("platform", sa.String(), nullable=False),
        sa.Column("target_kind", sa.String(), nullable=False, server_default="service"),
        sa.Column("target_name", sa.String(), nullable=False),
        sa.Column("status", sa.String(), nullable=False),
        sa.Column("summary", sa.String(), nullable=False, server_default=""),
        sa.Column("leading_rule", sa.String()),
        sa.Column("leading_certainty", sa.String()),
        sa.Column("contract_status", sa.String(), nullable=False),
        sa.Column("contract_violations", postgresql.JSONB(), nullable=False, server_default="[]"),
        sa.Column("agent_version", sa.String()),
        sa.Column("document", postgresql.JSONB(), nullable=False),
        sa.Column("collected_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("received_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.UniqueConstraint("agent_id", "diagnosis_id", name="uq_diagnoses_agent_run"),
        sa.CheckConstraint("contract_status IN ('ok', 'violation')", name="ck_diagnoses_contract_status"),
    )
    op.create_index("idx_diagnoses_target", "diagnoses", ["agent_id", "target_name", "collected_at"])


def downgrade() -> None:
    op.drop_index("idx_diagnoses_target", table_name="diagnoses")
    op.drop_table("diagnoses")
