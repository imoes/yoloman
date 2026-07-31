"""host_capabilities: the Lego capability inventory per host (derived from installed roles)

Revision ID: a1c9e4f2b7d3
Revises: f4a7b2c8d519
"""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision = "a1c9e4f2b7d3"
down_revision = "f4a7b2c8d519"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "host_capabilities",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("tenant_id", UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False),
        sa.Column("agent_id", UUID(as_uuid=True), sa.ForeignKey("agents.id", ondelete="CASCADE"), nullable=False),
        sa.Column("kind", sa.String(), nullable=False),
        sa.Column("capability", sa.String(), nullable=False),
        sa.Column("backend", sa.String(), nullable=True),
        sa.Column("template", sa.String(), nullable=False),
        sa.Column("source", sa.String(), nullable=False, server_default="derived"),
        sa.Column("port", sa.Integer(), nullable=True),
        sa.Column("config_path", sa.String(), nullable=True),
        sa.Column("detail", JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.CheckConstraint("kind IN ('provide', 'require')", name="ck_host_capabilities_kind"),
        sa.CheckConstraint("source IN ('derived', 'explicit')", name="ck_host_capabilities_source"),
        sa.UniqueConstraint("agent_id", "kind", "capability", "template", name="uq_host_capabilities_identity"),
    )
    op.create_index("idx_host_capabilities_agent", "host_capabilities", ["agent_id"])
    op.create_index("idx_host_capabilities_lookup", "host_capabilities", ["capability", "backend"])


def downgrade() -> None:
    op.drop_index("idx_host_capabilities_lookup", table_name="host_capabilities")
    op.drop_index("idx_host_capabilities_agent", table_name="host_capabilities")
    op.drop_table("host_capabilities")
