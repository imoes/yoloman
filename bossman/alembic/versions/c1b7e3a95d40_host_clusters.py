"""C1: host_clusters + cluster_nodes — a host whose services come from several nodes

Revision ID: c1b7e3a95d40
Revises: a4e6d9f21b58

We already monitor Proxmox/Ceph/DRBD, which ARE clusters, and "is the cluster healthy" was
only answerable per node. Checkmk's answer is a cluster HOST with a `nodes` attribute, and
that shape is worth copying: the cluster then has services, problems, acknowledgement,
downtime and notification like any other host.

So the cluster is an `agents` row (mode="cluster", no address — nothing polls it) and these
two tables hold what it needs beyond a host. Membership is many-to-many as in Checkmk: a
node can belong to more than one cluster.

`primary_node_id` uses ON DELETE SET NULL rather than CASCADE: removing the preferred node
of a failover cluster must not delete the cluster, it must fall back to the "no preference"
behaviour (services/clustering picks deterministically by name).
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "c1b7e3a95d40"
down_revision = "a4e6d9f21b58"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # A cluster host is an agents row with mode="cluster", and mode is CHECK-constrained to
    # standalone|satellite|proxy since the initial schema — so the constraint has to learn
    # the new value before any cluster can be created. (Found by the API returning 500:
    # "new row for relation agents violates check constraint ck_agents_mode".)
    op.drop_constraint("ck_agents_mode", "agents", type_="check")
    op.create_check_constraint(
        "ck_agents_mode", "agents", "mode IN ('standalone', 'satellite', 'proxy', 'cluster')"
    )
    op.create_table(
        "host_clusters",
        sa.Column("agent_id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("aggregation_mode", sa.String(), nullable=False, server_default="worst"),
        sa.Column("primary_node_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("service_patterns", postgresql.JSONB(), nullable=False, server_default="[]"),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.ForeignKeyConstraint(["agent_id"], ["agents.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["primary_node_id"], ["agents.id"], ondelete="SET NULL"),
    )
    op.create_table(
        "cluster_nodes",
        sa.Column("cluster_agent_id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("node_agent_id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.ForeignKeyConstraint(["cluster_agent_id"], ["agents.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["node_agent_id"], ["agents.id"], ondelete="CASCADE"),
    )
    # "which clusters is this node in" runs once per node per aggregation pass.
    op.create_index("ix_cluster_nodes_node", "cluster_nodes", ["node_agent_id"])


def downgrade() -> None:
    op.drop_constraint("ck_agents_mode", "agents", type_="check")
    op.create_check_constraint("ck_agents_mode", "agents", "mode IN ('standalone', 'satellite', 'proxy')")
    op.drop_index("ix_cluster_nodes_node", table_name="cluster_nodes")
    op.drop_table("cluster_nodes")
    op.drop_table("host_clusters")
