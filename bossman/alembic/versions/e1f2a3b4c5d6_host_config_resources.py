"""host_config_resources: desired config values per host (K3)

The fleet-side key-value database — one row per (agent, path) holding the
desired config values (codec) or template+values (Class-B), written on apply.
Drift = these values re-planned against the host's observed state.

Revision ID: e1f2a3b4c5d6
Revises: d0e1f2a3b4c5
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision = "e1f2a3b4c5d6"
down_revision = "d0e1f2a3b4c5"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "host_config_resources",
        sa.Column("id", UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")),
        sa.Column("tenant_id", UUID(as_uuid=True), nullable=False),
        sa.Column("agent_id", UUID(as_uuid=True), nullable=False),
        sa.Column("path", sa.String(), nullable=False),
        sa.Column("type", sa.String(), nullable=False, server_default="config"),
        sa.Column("config_format", sa.String(), nullable=True),
        sa.Column("separator", sa.String(), nullable=True),
        sa.Column("values", JSONB(), nullable=False, server_default="{}"),
        sa.Column("template", sa.Text(), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.Column("updated_by", sa.String(), nullable=True),
        sa.ForeignKeyConstraint(["agent_id"], ["agents.id"], ondelete="CASCADE"),
        sa.UniqueConstraint("agent_id", "path", name="uq_host_config_resources_agent_path"),
    )
    op.create_index("idx_host_config_resources_agent", "host_config_resources", ["agent_id"])


def downgrade() -> None:
    op.drop_index("idx_host_config_resources_agent", table_name="host_config_resources")
    op.drop_table("host_config_resources")
