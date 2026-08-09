"""L6: host_parents — UNREACHABLE distinct from DOWN

Revision ID: b8f4c2e17a93
Revises: c1b7e3a95d40

A host that cannot be reached while its parent is also unreachable is UNREACHABLE, not DOWN.
Its own state is unknown rather than bad, and it must not page — the parent's outage is the
single event worth telling anyone about, which is the same "one problem per outage" rule L3
established for a dead host's services.

Only the parents nobody can derive go here (a switch, a router). The proxy relation
(agents.parent_agent_id) is already a reachability parent and is treated as one implicitly:
if Bossman cannot reach a proxy it cannot reach the satellites behind it, and that needs no
configuration to be true. On this fleet that already covers minikube / nginx / bm-node-web /
bm-canvas-web behind docker-test.

Many-to-many, as in Checkmk: with several parents, ONE reachable parent makes the host's own
failure its own fault again.
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "b8f4c2e17a93"
down_revision = "c1b7e3a95d40"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "host_parents",
        sa.Column("child_agent_id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("parent_agent_id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.ForeignKeyConstraint(["child_agent_id"], ["agents.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["parent_agent_id"], ["agents.id"], ondelete="CASCADE"),
    )
    # "who are this host's parents" runs once per unreachable host per poll.
    op.create_index("ix_host_parents_child", "host_parents", ["child_agent_id"])


def downgrade() -> None:
    op.drop_index("ix_host_parents_child", table_name="host_parents")
    op.drop_table("host_parents")
