"""Kubernetes clusters — administered through an access host (project kubernetes-console).

Revision ID: a9c4e2f7b1d3
Revises: c7e52a91d4b8
Create Date: 2026-10-09
"""

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = "a9c4e2f7b1d3"
down_revision = "c7e52a91d4b8"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "kubernetes_clusters",
        sa.Column("id", postgresql.UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("tenant_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"),
                  nullable=False, server_default="00000000-0000-0000-0000-000000000001"),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("agent_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("agents.id", ondelete="CASCADE"), nullable=False),
        sa.Column("context", sa.String()),
        sa.Column("kubeconfig_path", sa.String()),
        sa.Column("description", sa.String()),
        sa.Column("server_url", sa.String()),
        sa.Column("server_version", sa.String()),
        sa.Column("node_count", sa.Integer()),
        sa.Column("namespace_count", sa.Integer()),
        sa.Column("reachability", sa.String(), nullable=False, server_default="never"),
        sa.Column("unreachable_reason", sa.String()),
        sa.Column("inventory", postgresql.JSONB(), nullable=False, server_default="{}"),
        sa.Column("observed_at", sa.DateTime(timezone=True)),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.UniqueConstraint("tenant_id", "name", name="uq_kubernetes_cluster_name"),
        sa.CheckConstraint("reachability IN ('reachable', 'unreachable', 'never')",
                           name="ck_kubernetes_clusters_reachability"),
    )
    op.create_index("idx_kubernetes_clusters_agent", "kubernetes_clusters", ["agent_id"])


def downgrade() -> None:
    op.drop_index("idx_kubernetes_clusters_agent", table_name="kubernetes_clusters")
    op.drop_table("kubernetes_clusters")
