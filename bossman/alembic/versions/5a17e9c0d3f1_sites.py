"""sites: subnet-scoped policy target (AD Sites-and-Services)

A Site is a policy scope defined by subnets (CIDRs); a host belongs to a site
when its primary IP is in one of them. Adds the sites table and a site_id scope
to config_policies and orchestration_plan_links (GPO precedence
global < OU < Site < group < host).

Revision ID: 5a17e9c0d3f1
Revises: d1a4f8c3b6e2
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql


revision = "5a17e9c0d3f1"
down_revision = "d1a4f8c3b6e2"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "sites",
        sa.Column("id", postgresql.UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("tenant_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("ou_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("description", sa.String(), nullable=False, server_default=""),
        sa.Column("subnets", postgresql.ARRAY(sa.String()), nullable=False, server_default=sa.text("'{}'")),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["tenant_id"], ["tenants.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["ou_id"], ["ou_nodes.id"], ondelete="SET NULL"),
        sa.UniqueConstraint("tenant_id", "name", name="uq_sites_tenant_name"),
    )

    # config_policies: add the site scope (mirror of host_group_id).
    op.add_column("config_policies", sa.Column("site_id", postgresql.UUID(as_uuid=True), nullable=True))
    op.create_foreign_key(
        "fk_config_policies_site", "config_policies", "sites", ["site_id"], ["id"], ondelete="CASCADE"
    )
    op.create_unique_constraint("uq_config_policies_site_path", "config_policies", ["site_id", "path"])
    op.create_index("idx_config_policies_site", "config_policies", ["site_id"])

    # orchestration_plan_links: add the site target + allow 'site' in the CHECK.
    op.add_column("orchestration_plan_links", sa.Column("site_id", postgresql.UUID(as_uuid=True), nullable=True))
    op.create_foreign_key(
        "fk_orchestration_plan_links_site", "orchestration_plan_links", "sites", ["site_id"], ["id"], ondelete="CASCADE"
    )
    op.drop_constraint("ck_orchestration_plan_links_target_type", "orchestration_plan_links", type_="check")
    op.create_check_constraint(
        "ck_orchestration_plan_links_target_type",
        "orchestration_plan_links",
        "target_type IN ('ou', 'host', 'group', 'site', 'label_selector', 'global')",
    )


def downgrade() -> None:
    op.drop_constraint("ck_orchestration_plan_links_target_type", "orchestration_plan_links", type_="check")
    op.create_check_constraint(
        "ck_orchestration_plan_links_target_type",
        "orchestration_plan_links",
        "target_type IN ('ou', 'host', 'group', 'label_selector', 'global')",
    )
    op.drop_constraint("fk_orchestration_plan_links_site", "orchestration_plan_links", type_="foreignkey")
    op.drop_column("orchestration_plan_links", "site_id")

    op.drop_index("idx_config_policies_site", table_name="config_policies")
    op.drop_constraint("uq_config_policies_site_path", "config_policies", type_="unique")
    op.drop_constraint("fk_config_policies_site", "config_policies", type_="foreignkey")
    op.drop_column("config_policies", "site_id")

    op.drop_table("sites")
