"""policy/orchestration L3a: ltree OU paths, block_inheritance, OU-scoped rules

Revision ID: d4c8e1f9a3b7
Revises: c7e4d81a9f52
Create Date: 2026-07-08

Block L3a — the GPO/LDAP foundation (see docs/policy-orchestration-architecture.md):

  * `ltree` extension + `ou_nodes.ltree_path ltree` (GiST-indexed) for real
    ancestor/descendant queries (@>/<@), alongside the human-readable varchar
    `path` and `parent_id` that L1 already has. Existing rows are backfilled by
    sanitizing `path` into ltree labels (leading '/' stripped, '/' -> '.',
    anything outside [A-Za-z0-9_-] -> '_'; PG16 ltree allows '-').
  * `ou_nodes.block_inheritance` — the GPO "Block Inheritance" container property.
  * All rule types gain OU binding + GPO precedence fields, additively (no generic
    rules table): `check_rules` gets scope_type='ou' + scope_ou_id + enforced +
    link_order; `notification_rules` gets ou_id + enforced + link_order.
    orchestration_plan_links already carry ou_id/enforced/enabled/link_order (L1).

Exact GPO semantics (LSDOU top-down, enforced beats lower + pierces block
inheritance, block inheritance drops inherited non-enforced from above) live in
services/compiler._resolve_gpo_winner, not in the schema.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = "d4c8e1f9a3b7"
down_revision: Union[str, Sequence[str], None] = "c7e4d81a9f52"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute("CREATE EXTENSION IF NOT EXISTS ltree")

    # --- ou_nodes: ltree_path + block_inheritance ---
    op.execute("ALTER TABLE ou_nodes ADD COLUMN ltree_path ltree")
    op.execute(
        # Backfill from the human path: strip leading '/', map '/'->'.', and
        # replace any char outside the ltree label set with '_'. A root-only
        # tenant with no OUs simply has nothing to backfill.
        r"""
        UPDATE ou_nodes SET ltree_path = text2ltree(
            regexp_replace(
                regexp_replace(trim(leading '/' from path), '[^A-Za-z0-9/_-]', '_', 'g'),
                '/', '.', 'g'
            )
        )
        WHERE path <> '' AND path <> '/'
        """
    )
    # Any row whose path was empty/root gets a safe single-label fallback so the
    # NOT NULL below holds (shouldn't happen — OU paths always have >=1 segment).
    op.execute("UPDATE ou_nodes SET ltree_path = text2ltree('root') WHERE ltree_path IS NULL")
    op.execute("ALTER TABLE ou_nodes ALTER COLUMN ltree_path SET NOT NULL")
    op.execute("CREATE INDEX ix_ou_nodes_ltree_gist ON ou_nodes USING gist (ltree_path)")

    op.add_column(
        "ou_nodes",
        sa.Column("block_inheritance", sa.Boolean(), nullable=False, server_default=sa.text("false")),
    )

    # --- check_rules: OU scope + GPO precedence fields ---
    op.add_column("check_rules", sa.Column("scope_ou_id", UUID(as_uuid=True), nullable=True))
    op.add_column("check_rules", sa.Column("enforced", sa.Boolean(), nullable=False, server_default=sa.text("false")))
    op.add_column("check_rules", sa.Column("link_order", sa.Integer(), nullable=False, server_default="100"))
    op.create_foreign_key(
        "fk_check_rules_scope_ou_id", "check_rules", "ou_nodes", ["scope_ou_id"], ["id"], ondelete="CASCADE"
    )
    # Widen scope_type to include 'ou' and re-anchor the value/ou-id constraint.
    op.drop_constraint("ck_check_rules_scope_type", "check_rules", type_="check")
    op.drop_constraint("ck_check_rules_scope_value_matches_type", "check_rules", type_="check")
    op.create_check_constraint(
        "ck_check_rules_scope_type", "check_rules", "scope_type IN ('global', 'group', 'host', 'ou')"
    )
    op.create_check_constraint(
        "ck_check_rules_scope_value_matches_type",
        "check_rules",
        "(scope_type = 'global' AND scope_value IS NULL AND scope_ou_id IS NULL) OR "
        "(scope_type IN ('group', 'host') AND scope_value IS NOT NULL AND scope_ou_id IS NULL) OR "
        "(scope_type = 'ou' AND scope_ou_id IS NOT NULL AND scope_value IS NULL)",
    )

    # --- notification_rules: OU binding + GPO precedence fields ---
    op.add_column("notification_rules", sa.Column("ou_id", UUID(as_uuid=True), nullable=True))
    op.add_column(
        "notification_rules", sa.Column("enforced", sa.Boolean(), nullable=False, server_default=sa.text("false"))
    )
    op.add_column("notification_rules", sa.Column("link_order", sa.Integer(), nullable=False, server_default="100"))
    op.create_foreign_key(
        "fk_notification_rules_ou_id", "notification_rules", "ou_nodes", ["ou_id"], ["id"], ondelete="CASCADE"
    )


def downgrade() -> None:
    op.drop_constraint("fk_notification_rules_ou_id", "notification_rules", type_="foreignkey")
    op.drop_column("notification_rules", "link_order")
    op.drop_column("notification_rules", "enforced")
    op.drop_column("notification_rules", "ou_id")

    op.drop_constraint("ck_check_rules_scope_value_matches_type", "check_rules", type_="check")
    op.drop_constraint("ck_check_rules_scope_type", "check_rules", type_="check")
    op.create_check_constraint(
        "ck_check_rules_scope_type", "check_rules", "scope_type IN ('global', 'group', 'host')"
    )
    op.create_check_constraint(
        "ck_check_rules_scope_value_matches_type",
        "check_rules",
        "(scope_type = 'global' AND scope_value IS NULL) OR "
        "(scope_type IN ('group', 'host') AND scope_value IS NOT NULL)",
    )
    op.drop_constraint("fk_check_rules_scope_ou_id", "check_rules", type_="foreignkey")
    op.drop_column("check_rules", "link_order")
    op.drop_column("check_rules", "enforced")
    op.drop_column("check_rules", "scope_ou_id")

    op.drop_column("ou_nodes", "block_inheritance")
    op.execute("DROP INDEX IF EXISTS ix_ou_nodes_ltree_gist")
    op.drop_column("ou_nodes", "ltree_path")
