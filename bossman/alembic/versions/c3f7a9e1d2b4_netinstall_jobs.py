"""Netinstall jobs — a VM installed by its distribution's own installer (kickstart), not a restored image
(docs/kernel-tuning.md, "Test hosts through MCP"). The PXE DHCP serves exactly the MACs of the active jobs.

Revision ID: c3f7a9e1d2b4
Revises: b8d1a6c3e4f2
Create Date: 2026-10-18
"""

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = "c3f7a9e1d2b4"
down_revision = "b8d1a6c3e4f2"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "netinstall_jobs",
        sa.Column("id", postgresql.UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("target_mac", sa.String(), nullable=False),
        sa.Column("hostname", sa.String(), nullable=False),
        sa.Column("distro", sa.String(), nullable=False),
        sa.Column("release", sa.String(), nullable=False),
        sa.Column("network", postgresql.JSONB(), nullable=False, server_default="{}"),
        sa.Column("packages", postgresql.JSONB(), nullable=False, server_default="[]"),
        # pending (armed, DHCP open for its MAC) | installing (the installer fetched its kickstart) |
        # done (the new host's agent reported) | failed | cancelled
        sa.Column("status", sa.String(), nullable=False, server_default="pending"),
        sa.Column("kickstart", sa.Text(), nullable=False),
        sa.Column("ks_path", sa.String(), nullable=False),
        sa.Column("agent_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("agents.id", ondelete="SET NULL")),
        sa.Column("vm_host_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("vm_hosts.id", ondelete="SET NULL")),
        sa.Column("vm_node", sa.String()),
        sa.Column("vm_id", sa.String()),
        sa.Column("error", sa.Text()),
        sa.Column("created_by", sa.String()),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("finished_at", sa.DateTime(timezone=True)),
    )
    op.create_index("ix_netinstall_jobs_mac_active", "netinstall_jobs", ["target_mac"], unique=True,
                    postgresql_where=sa.text("status IN ('pending', 'installing')"))


def downgrade() -> None:
    op.drop_index("ix_netinstall_jobs_mac_active", table_name="netinstall_jobs")
    op.drop_table("netinstall_jobs")
