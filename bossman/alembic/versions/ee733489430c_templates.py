"""templates: named, live-linked, nestable check-rule bundles (Block K12)

Revision ID: ee733489430c
Revises: 5e81d459a395
Create Date: 2026-07-08

Zabbix gap-analysis Block K12 — the biggest single gap this analysis
found: a named, reusable bundle of monitoring definitions, live-linked
(not copied) to a host group so editing the template cascades to every
linked host, and nestable (a template can include other templates'
rules). Scoped to check-rule bundling for v1 — the piece buildable today;
extends to bundle custom graphs (Block K11, just landed)/discovery rules/
web scenarios once those primitives exist in later gap-analysis batches
(see docs/zabbix-gap-analysis.md's Batch 4 notes).

`check_rules` gains template_id (which template owns this materialized
row, if any) and source_template_rule_id (which exact TemplateRule it was
generated from — the identity key re-materialization upserts by).
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision: str = "ee733489430c"
down_revision: Union[str, Sequence[str], None] = "5e81d459a395"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "template_groups",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), nullable=False),
        sa.Column("name", sa.String(), nullable=False),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("name", name="uq_template_groups_name"),
    )
    op.create_table(
        "templates",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), nullable=False),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("description", sa.String(), nullable=False, server_default=""),
        sa.Column("template_group_id", UUID(as_uuid=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.ForeignKeyConstraint(["template_group_id"], ["template_groups.id"], ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("name", name="uq_templates_name"),
    )
    op.create_table(
        "template_rules",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), nullable=False),
        sa.Column("template_id", UUID(as_uuid=True), nullable=False),
        sa.Column("service_name", sa.String(), nullable=False),
        sa.Column("metric", sa.String(), nullable=False),
        sa.Column("comparison", sa.String(), nullable=False),
        sa.Column("warn_threshold", sa.Float(), nullable=True),
        sa.Column("crit_threshold", sa.Float(), nullable=True),
        sa.Column("label_value", sa.String(), nullable=True),
        sa.Column("max_attempts", sa.Integer(), nullable=True),
        sa.Column("recovery_threshold", sa.Float(), nullable=True),
        sa.Column("value_map_id", UUID(as_uuid=True), nullable=True),
        sa.Column("depends_on_service_name", sa.String(), nullable=True),
        sa.Column("extra_conditions", JSONB(astext_type=sa.Text()), nullable=True),
        sa.Column("condition_logic", sa.String(), nullable=False, server_default="AND"),
        sa.ForeignKeyConstraint(["template_id"], ["templates.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["value_map_id"], ["value_maps.id"], ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id"),
        sa.CheckConstraint("comparison IN ('gt', 'lt', 'ge', 'le', 'eq', 'ne')", name="ck_template_rules_comparison"),
        sa.CheckConstraint("condition_logic IN ('AND', 'OR')", name="ck_template_rules_condition_logic"),
    )
    op.create_table(
        "template_nesting",
        sa.Column("parent_template_id", UUID(as_uuid=True), nullable=False),
        sa.Column("child_template_id", UUID(as_uuid=True), nullable=False),
        sa.ForeignKeyConstraint(["parent_template_id"], ["templates.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["child_template_id"], ["templates.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("parent_template_id", "child_template_id"),
        sa.CheckConstraint("parent_template_id != child_template_id", name="ck_template_nesting_no_self_nest"),
    )
    op.create_table(
        "template_links",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), nullable=False),
        sa.Column("template_id", UUID(as_uuid=True), nullable=False),
        sa.Column("host_group", sa.String(), nullable=False),
        sa.ForeignKeyConstraint(["template_id"], ["templates.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("template_id", "host_group", name="uq_template_links_template_group"),
    )
    op.add_column("check_rules", sa.Column("template_id", UUID(as_uuid=True), nullable=True))
    op.add_column("check_rules", sa.Column("source_template_rule_id", UUID(as_uuid=True), nullable=True))
    op.create_foreign_key(
        "fk_check_rules_template_id", "check_rules", "templates", ["template_id"], ["id"], ondelete="CASCADE"
    )
    op.create_foreign_key(
        "fk_check_rules_source_template_rule_id",
        "check_rules", "template_rules", ["source_template_rule_id"], ["id"], ondelete="CASCADE",
    )


def downgrade() -> None:
    op.drop_constraint("fk_check_rules_source_template_rule_id", "check_rules", type_="foreignkey")
    op.drop_constraint("fk_check_rules_template_id", "check_rules", type_="foreignkey")
    op.drop_column("check_rules", "source_template_rule_id")
    op.drop_column("check_rules", "template_id")
    op.drop_table("template_links")
    op.drop_table("template_nesting")
    op.drop_table("template_rules")
    op.drop_table("templates")
    op.drop_table("template_groups")
