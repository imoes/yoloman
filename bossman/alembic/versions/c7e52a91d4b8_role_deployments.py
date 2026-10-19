"""SCCM-style desired-state deployments for roles and features.

Revision ID: c7e52a91d4b8
Revises: b6d41f27ac83
Create Date: 2026-09-23
"""

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = "c7e52a91d4b8"
down_revision = "b6d41f27ac83"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.drop_constraint("ck_orchestration_plans_plan_type", "orchestration_plans", type_="check")
    op.create_check_constraint(
        "ck_orchestration_plans_plan_type", "orchestration_plans",
        "plan_type IN ('role', 'feature', 'cluster', 'deployment', 'remediation', 'maintenance', 'bootstrap')",
    )
    op.create_table(
        "role_deployments",
        sa.Column("id", postgresql.UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("tenant_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("scope_type", sa.String(), nullable=False),
        sa.Column("agent_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("agents.id", ondelete="CASCADE")),
        sa.Column("ou_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("ou_nodes.id", ondelete="CASCADE")),
        sa.Column("host_group_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("host_groups.id", ondelete="CASCADE")),
        sa.Column("site_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("sites.id", ondelete="CASCADE")),
        sa.Column("status", sa.String(), nullable=False, server_default="draft"),
        sa.Column("require_approval", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("pilot_enabled", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("target_hash", sa.String(), nullable=False),
        sa.Column("removal_behavior", sa.String(), nullable=False, server_default="unmanage"),
        sa.Column("created_by", sa.String()),
        sa.Column("approved_by", sa.String()),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.CheckConstraint("scope_type IN ('host', 'group', 'ou', 'site', 'global')", name="ck_role_deployments_scope"),
        sa.CheckConstraint("status IN ('draft', 'pending_approval', 'active', 'paused', 'failed', 'retired')", name="ck_role_deployments_status"),
        sa.CheckConstraint("removal_behavior IN ('unmanage', 'uninstall')", name="ck_role_deployments_removal"),
    )
    op.create_table(
        "role_deployment_items",
        sa.Column("id", postgresql.UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("deployment_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("role_deployments.id", ondelete="CASCADE"), nullable=False),
        sa.Column("plan_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("orchestration_plans.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("plan_version", sa.Integer(), nullable=False),
        sa.Column("parameters", postgresql.JSONB(), nullable=False, server_default="{}"),
        sa.Column("item_order", sa.Integer(), nullable=False, server_default="0"),
        sa.UniqueConstraint("deployment_id", "plan_id", name="uq_role_deployment_item_plan"),
    )
    op.create_table(
        "role_deployment_targets",
        sa.Column("id", postgresql.UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("deployment_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("role_deployments.id", ondelete="CASCADE"), nullable=False),
        sa.Column("item_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("role_deployment_items.id", ondelete="CASCADE"), nullable=False),
        sa.Column("agent_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("agents.id", ondelete="CASCADE"), nullable=False),
        sa.Column("phase", sa.String(), nullable=False, server_default="main"),
        sa.Column("state", sa.String(), nullable=False, server_default="pending"),
        sa.Column("desired_hash", sa.String(), nullable=False),
        sa.Column("excluded", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("correction_requested", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("link_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("orchestration_plan_links.id", ondelete="SET NULL")),
        sa.Column("last_error", sa.Text()),
        sa.Column("result", postgresql.JSONB(), nullable=False, server_default="{}"),
        sa.Column("detected_at", sa.DateTime(timezone=True)),
        sa.Column("applied_at", sa.DateTime(timezone=True)),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.UniqueConstraint("item_id", "agent_id", name="uq_role_deployment_target_item_agent"),
        sa.CheckConstraint("phase IN ('pilot', 'main', 'steady')", name="ck_role_deployment_targets_phase"),
        sa.CheckConstraint("state IN ('pending', 'not_applicable', 'blocked', 'installing', 'compliant', 'noncompliant', 'unknown', 'error', 'unmanaged')", name="ck_role_deployment_targets_state"),
    )
    op.create_index("ix_role_deployment_targets_state", "role_deployment_targets", ["state"])


def downgrade() -> None:
    op.drop_index("ix_role_deployment_targets_state", table_name="role_deployment_targets")
    op.drop_table("role_deployment_targets")
    op.drop_table("role_deployment_items")
    op.drop_table("role_deployments")
    op.drop_constraint("ck_orchestration_plans_plan_type", "orchestration_plans", type_="check")
    op.create_check_constraint(
        "ck_orchestration_plans_plan_type", "orchestration_plans",
        "plan_type IN ('role', 'cluster', 'deployment', 'remediation', 'maintenance', 'bootstrap')",
    )
