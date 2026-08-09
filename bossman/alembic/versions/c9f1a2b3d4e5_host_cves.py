"""host_cves: CVEs a pending upgrade would fix, per host (Block 4-C)

Revision ID: c9f1a2b3d4e5
Revises: d4a9c1e6b8f2
Create Date: 2026-07-11

Correlated from package_updates × the cached CVE feed. Replace-on-collect per
agent. Additive.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = "c9f1a2b3d4e5"
down_revision: Union[str, Sequence[str], None] = "d4a9c1e6b8f2"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "host_cves",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("agent_id", UUID(as_uuid=True), sa.ForeignKey("agents.id", ondelete="CASCADE"), nullable=False),
        sa.Column("cve", sa.String(), nullable=False),
        sa.Column("package", sa.String(), nullable=False),
        sa.Column("source_package", sa.String(), nullable=False, server_default=""),
        sa.Column("current_version", sa.String(), nullable=False, server_default=""),
        sa.Column("fixed_version", sa.String(), nullable=False, server_default=""),
        sa.Column("severity", sa.String(), nullable=False, server_default=""),
        sa.Column("distro", sa.String(), nullable=False, server_default=""),
        sa.Column("collected_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index("idx_host_cves_agent", "host_cves", ["agent_id"])
    op.create_index("idx_host_cves_cve", "host_cves", ["cve"])
    op.create_index("idx_host_cves_severity", "host_cves", ["severity"])


def downgrade() -> None:
    op.drop_index("idx_host_cves_severity", table_name="host_cves")
    op.drop_index("idx_host_cves_cve", table_name="host_cves")
    op.drop_index("idx_host_cves_agent", table_name="host_cves")
    op.drop_table("host_cves")
