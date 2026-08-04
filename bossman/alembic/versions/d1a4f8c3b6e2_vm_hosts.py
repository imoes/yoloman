"""vm_hosts: hypervisors (vCenter / Proxmox) the provisioner can create VMs on

Credentials stored vault-encrypted; kind is auto-detected from host+creds.

Revision ID: d1a4f8c3b6e2
Revises: c9f2a7b4e1d8
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "d1a4f8c3b6e2"
down_revision = "c9f2a7b4e1d8"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "vm_hosts",
        sa.Column("id", postgresql.UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("tenant_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("kind", sa.String(), nullable=False),
        sa.Column("host", sa.String(), nullable=False),
        sa.Column("username", sa.String(), nullable=False),
        sa.Column("secret", sa.Text(), nullable=False),
        sa.Column("verify_tls", sa.Boolean(), nullable=False, server_default=sa.text("false")),
        sa.Column("created_by", sa.String(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("tenant_id", "name", name="uq_vm_hosts_name"),
        sa.CheckConstraint("kind IN ('proxmox', 'vcenter')", name="ck_vm_hosts_kind"),
    )


def downgrade() -> None:
    op.drop_table("vm_hosts")
