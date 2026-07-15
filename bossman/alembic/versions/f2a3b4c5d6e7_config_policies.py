"""config_policies: OU-scoped config resources (K4)

An OU-scoped config resource (values or template+values) applying to every host
under the OU — config policy, "Host A = Host B". A host's effective desired
config per path is the GPO winner (host-direct wins over deepest OU).

Revision ID: f2a3b4c5d6e7
Revises: e1f2a3b4c5d6
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision = "f2a3b4c5d6e7"
down_revision = "e1f2a3b4c5d6"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "config_policies",
        sa.Column("id", UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")),
        sa.Column("tenant_id", UUID(as_uuid=True), nullable=False),
        sa.Column("scope_ou_id", UUID(as_uuid=True), nullable=False),
        sa.Column("path", sa.String(), nullable=False),
        sa.Column("type", sa.String(), nullable=False, server_default="config"),
        sa.Column("config_format", sa.String(), nullable=True),
        sa.Column("separator", sa.String(), nullable=True),
        sa.Column("values", JSONB(), nullable=False, server_default="{}"),
        sa.Column("template", sa.Text(), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.ForeignKeyConstraint(["scope_ou_id"], ["ou_nodes.id"], ondelete="CASCADE"),
        sa.UniqueConstraint("scope_ou_id", "path", name="uq_config_policies_ou_path"),
    )
    op.create_index("idx_config_policies_ou", "config_policies", ["scope_ou_id"])


def downgrade() -> None:
    op.drop_index("idx_config_policies_ou", table_name="config_policies")
    op.drop_table("config_policies")
