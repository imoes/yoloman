"""restore_jobs: bootstrap→production VLAN handoff fields

Provision a VM on a bootstrap VLAN (DHCP/TFTP/PE), then move its NIC to a
different production VLAN before the final boot. VLAN is hypervisor-level, so
the job must remember which VM to retag (vm_host_id / vm_node / vm_id) and the
production segment (production_vlan for Proxmox tag, production_bridge for the
bridge/portgroup). All nullable → opt-in; a job without them behaves as before.

Revision ID: 7c39a1e5b8d2
Revises: 6b28f0a1c4d5
Create Date: 2026-08-07
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "7c39a1e5b8d2"
down_revision: Union[str, Sequence[str], None] = "6b28f0a1c4d5"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("restore_jobs", sa.Column("vm_host_id", sa.UUID(), nullable=True))
    op.add_column("restore_jobs", sa.Column("vm_node", sa.String(), nullable=True))
    op.add_column("restore_jobs", sa.Column("vm_id", sa.String(), nullable=True))
    op.add_column("restore_jobs", sa.Column("production_vlan", sa.Integer(), nullable=True))
    op.add_column("restore_jobs", sa.Column("production_bridge", sa.String(), nullable=True))
    op.create_foreign_key(
        "fk_restore_jobs_vm_host_id", "restore_jobs", "vm_hosts",
        ["vm_host_id"], ["id"], ondelete="SET NULL",
    )


def downgrade() -> None:
    op.drop_constraint("fk_restore_jobs_vm_host_id", "restore_jobs", type_="foreignkey")
    op.drop_column("restore_jobs", "production_bridge")
    op.drop_column("restore_jobs", "production_vlan")
    op.drop_column("restore_jobs", "vm_id")
    op.drop_column("restore_jobs", "vm_node")
    op.drop_column("restore_jobs", "vm_host_id")
