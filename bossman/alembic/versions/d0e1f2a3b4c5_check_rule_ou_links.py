"""check_rule_ou_links: one threshold policy → many OUs

A check rule (threshold policy) previously pinned to a single OU via
scope_ou_id. This association table lets ONE policy link to MANY OUs (GPO-style
multi-link) without duplicating the rule. Resolution unions the primary
scope_ou_id with every linked OU.

Revision ID: d0e1f2a3b4c5
Revises: c9d0e1f2a3b4
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision = "d0e1f2a3b4c5"
down_revision = "c9d0e1f2a3b4"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "check_rule_ou_links",
        sa.Column("id", UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")),
        sa.Column("rule_id", UUID(as_uuid=True), nullable=False),
        sa.Column("ou_id", UUID(as_uuid=True), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.ForeignKeyConstraint(["rule_id"], ["check_rules.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["ou_id"], ["ou_nodes.id"], ondelete="CASCADE"),
        sa.UniqueConstraint("rule_id", "ou_id", name="uq_check_rule_ou_links_rule_ou"),
    )
    op.create_index("idx_check_rule_ou_links_rule", "check_rule_ou_links", ["rule_id"])


def downgrade() -> None:
    op.drop_index("idx_check_rule_ou_links_rule", table_name="check_rule_ou_links")
    op.drop_table("check_rule_ou_links")
