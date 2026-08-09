"""check_rules: site (subnet) scope for thresholds

Mirrors config_policies.site_id — a threshold rule can be scoped to a Site so
every host whose primary IP is in the site's subnets gets it. Precedence
LEVEL_SITE (global < group < OU < Site < host).

Revision ID: 6b28f0a1c4d5
Revises: 5a17e9c0d3f1
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision = "6b28f0a1c4d5"
down_revision = "5a17e9c0d3f1"
branch_labels = None
depends_on = None

_TYPE_OLD = "scope_type IN ('global', 'group', 'host', 'ou')"
_TYPE_NEW = "scope_type IN ('global', 'group', 'host', 'ou', 'site')"

_COUPLE_OLD = (
    "(scope_type = 'global' AND scope_value IS NULL AND scope_ou_id IS NULL) OR "
    "(scope_type IN ('group', 'host') AND scope_value IS NOT NULL AND scope_ou_id IS NULL) OR "
    "(scope_type = 'ou' AND scope_ou_id IS NOT NULL AND scope_value IS NULL)"
)
_COUPLE_NEW = (
    "(scope_type = 'global' AND scope_value IS NULL AND scope_ou_id IS NULL AND scope_site_id IS NULL) OR "
    "(scope_type IN ('group', 'host') AND scope_value IS NOT NULL AND scope_ou_id IS NULL AND scope_site_id IS NULL) OR "
    "(scope_type = 'ou' AND scope_ou_id IS NOT NULL AND scope_value IS NULL AND scope_site_id IS NULL) OR "
    "(scope_type = 'site' AND scope_site_id IS NOT NULL AND scope_value IS NULL AND scope_ou_id IS NULL)"
)


def upgrade() -> None:
    op.add_column("check_rules", sa.Column("scope_site_id", postgresql.UUID(as_uuid=True), nullable=True))
    op.create_foreign_key(
        "fk_check_rules_site", "check_rules", "sites", ["scope_site_id"], ["id"], ondelete="CASCADE"
    )
    op.drop_constraint("ck_check_rules_scope_type", "check_rules", type_="check")
    op.create_check_constraint("ck_check_rules_scope_type", "check_rules", _TYPE_NEW)
    op.drop_constraint("ck_check_rules_scope_value_matches_type", "check_rules", type_="check")
    op.create_check_constraint("ck_check_rules_scope_value_matches_type", "check_rules", _COUPLE_NEW)


def downgrade() -> None:
    op.drop_constraint("ck_check_rules_scope_value_matches_type", "check_rules", type_="check")
    op.create_check_constraint("ck_check_rules_scope_value_matches_type", "check_rules", _COUPLE_OLD)
    op.drop_constraint("ck_check_rules_scope_type", "check_rules", type_="check")
    op.create_check_constraint("ck_check_rules_scope_type", "check_rules", _TYPE_OLD)
    op.drop_constraint("fk_check_rules_site", "check_rules", type_="foreignkey")
    op.drop_column("check_rules", "scope_site_id")
