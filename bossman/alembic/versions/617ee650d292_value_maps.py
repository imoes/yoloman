"""value maps (Block K4)

Revision ID: 617ee650d292
Revises: cd09bed433e7
Create Date: 2026-07-07

Zabbix gap-analysis Block K4: reusable named numeric/string -> label
mappings (e.g. 0 -> "Down", 1 -> "Up"), attachable to a CheckRule so its
materialized Services can show a human label alongside the raw value.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision: str = "617ee650d292"
down_revision: Union[str, Sequence[str], None] = "cd09bed433e7"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "value_maps",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), nullable=False),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("mappings", JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("name", name="uq_value_maps_name"),
    )
    op.add_column("check_rules", sa.Column("value_map_id", UUID(as_uuid=True), nullable=True))
    op.create_foreign_key(
        "fk_check_rules_value_map_id",
        "check_rules",
        "value_maps",
        ["value_map_id"],
        ["id"],
        ondelete="SET NULL",
    )


def downgrade() -> None:
    op.drop_constraint("fk_check_rules_value_map_id", "check_rules", type_="foreignkey")
    op.drop_column("check_rules", "value_map_id")
    op.drop_table("value_maps")
