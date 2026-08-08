"""config_policies: Checkmk rule conditions (host_tags / labels / os / folder / …)

A config policy can now carry the same six-field condition set as check rules and
check assignments (services/rule_conditions), so a gpedit policy applies only to
hosts that also match its host_tags / host_label_groups / host_name / host_folder
/ service conditions — not just its structural OU/group/site scope. Empty (the
default and every existing row) = applies wherever the scope reaches, so the
change is transparent to existing policies.

Revision ID: b1e7c2a9f3d0
Revises: 8d4ab2f6c1e9
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision = "b1e7c2a9f3d0"
down_revision = "8d4ab2f6c1e9"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "config_policies",
        sa.Column(
            "conditions",
            postgresql.JSONB(astext_type=sa.Text()),
            nullable=False,
            server_default=sa.text("'{}'::jsonb"),
        ),
    )


def downgrade() -> None:
    op.drop_column("config_policies", "conditions")
