"""policy/orchestration layer L1: tenants, OU tree, host groups, plans, compiled state

Revision ID: b3f1a2c9d740
Revises: ee733489430c
Create Date: 2026-07-08

Block L1 of the Policy- & Orchestration layer (see docs/plan.md / the
approved L-series plan). Additive only — the existing `agents` and
`check_rules` schema and the monitoring rule-resolution logic are left
untouched. This migration lays the data foundation:

  * `tenants` — multi-tenancy from day one; a fixed default tenant is
    seeded so every existing agent can be backfilled deterministically.
  * `ou_nodes` — the OU tree (AD-style: a host lives at exactly one place
    in the tree). `path` is the materialized slash-path, matching the
    existing slash convention in `agents.groups`.
  * `host_groups` + `host_group_members` — first-class group objects
    (placed inside an OU) with many-to-many host membership; this is how a
    host gets multiple assignments in the AD model.
  * `orchestration_plans` / `_versions` / `_links` — a named, versioned,
    reusable bundle of steps + generated monitoring, linked to an OU / host
    / group / global (proposal §5, §9).
  * `compiled_host_state` — the per-host compiled desired state with a
    monotonic `generation` and a `config_hash`; only the current row per
    host carries is_current=true (enforced by a partial unique index).

`agents` gains additive tenant_id / ou_id FKs (tenant_id backfilled to the
default tenant, both nullable so existing inserts keep working unchanged).
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision: str = "b3f1a2c9d740"
down_revision: Union[str, Sequence[str], None] = "ee733489430c"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

# A fixed, well-known UUID for the seeded default tenant — deterministic so
# the agents backfill below and the test suite can both reference it without
# a lookup. Mirrors CheckRule's is_default seeding convention.
DEFAULT_TENANT_ID = "00000000-0000-0000-0000-000000000001"


def upgrade() -> None:
    op.create_table(
        "tenants",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), nullable=False),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("slug", sa.String(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("slug", name="uq_tenants_slug"),
    )
    op.execute(
        f"INSERT INTO tenants (id, name, slug) VALUES ('{DEFAULT_TENANT_ID}'::uuid, 'Default', 'default')"
    )

    op.create_table(
        "ou_nodes",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), nullable=False),
        sa.Column("tenant_id", UUID(as_uuid=True), nullable=False),
        sa.Column("parent_id", UUID(as_uuid=True), nullable=True),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("path", sa.String(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["tenant_id"], ["tenants.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["parent_id"], ["ou_nodes.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("tenant_id", "path", name="uq_ou_nodes_tenant_path"),
    )

    op.create_table(
        "host_groups",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), nullable=False),
        sa.Column("tenant_id", UUID(as_uuid=True), nullable=False),
        sa.Column("ou_id", UUID(as_uuid=True), nullable=True),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("description", sa.String(), nullable=False, server_default=""),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["tenant_id"], ["tenants.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["ou_id"], ["ou_nodes.id"], ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("tenant_id", "name", name="uq_host_groups_tenant_name"),
    )

    op.create_table(
        "host_group_members",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), nullable=False),
        sa.Column("tenant_id", UUID(as_uuid=True), nullable=False),
        sa.Column("host_group_id", UUID(as_uuid=True), nullable=False),
        sa.Column("agent_id", UUID(as_uuid=True), nullable=False),
        sa.ForeignKeyConstraint(["tenant_id"], ["tenants.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["host_group_id"], ["host_groups.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["agent_id"], ["agents.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("host_group_id", "agent_id", name="uq_host_group_members_group_agent"),
    )

    op.create_table(
        "orchestration_plans",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), nullable=False),
        sa.Column("tenant_id", UUID(as_uuid=True), nullable=False),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("display_name", sa.String(), nullable=False),
        sa.Column("description", sa.String(), nullable=False, server_default=""),
        sa.Column("plan_type", sa.String(), nullable=False),
        sa.Column("enabled", sa.Boolean(), nullable=False, server_default=sa.text("true")),
        sa.Column("current_version", sa.Integer(), nullable=False, server_default="1"),
        sa.Column("created_by", sa.String(), nullable=True),
        sa.Column("updated_by", sa.String(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["tenant_id"], ["tenants.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("tenant_id", "name", name="uq_orchestration_plans_tenant_name"),
        sa.CheckConstraint(
            "plan_type IN ('role', 'cluster', 'deployment', 'remediation', 'maintenance', 'bootstrap')",
            name="ck_orchestration_plans_plan_type",
        ),
    )

    op.create_table(
        "orchestration_plan_versions",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), nullable=False),
        sa.Column("tenant_id", UUID(as_uuid=True), nullable=False),
        sa.Column("plan_id", UUID(as_uuid=True), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("parameter_schema", JSONB(astext_type=sa.Text()), nullable=False, server_default="{}"),
        sa.Column("default_parameters", JSONB(astext_type=sa.Text()), nullable=False, server_default="{}"),
        sa.Column("requirements", JSONB(astext_type=sa.Text()), nullable=False, server_default="{}"),
        sa.Column("steps", JSONB(astext_type=sa.Text()), nullable=False, server_default="[]"),
        sa.Column("rollback_steps", JSONB(astext_type=sa.Text()), nullable=False, server_default="[]"),
        sa.Column("validation_steps", JSONB(astext_type=sa.Text()), nullable=False, server_default="[]"),
        sa.Column("generated_monitoring", JSONB(astext_type=sa.Text()), nullable=False, server_default="{}"),
        sa.Column("generated_notifications", JSONB(astext_type=sa.Text()), nullable=False, server_default="{}"),
        sa.Column("created_by", sa.String(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.ForeignKeyConstraint(["tenant_id"], ["tenants.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["plan_id"], ["orchestration_plans.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("tenant_id", "plan_id", "version", name="uq_orchestration_plan_versions_plan_version"),
    )

    op.create_table(
        "orchestration_plan_links",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), nullable=False),
        sa.Column("tenant_id", UUID(as_uuid=True), nullable=False),
        sa.Column("plan_id", UUID(as_uuid=True), nullable=False),
        sa.Column("plan_version", sa.Integer(), nullable=True),
        sa.Column("target_type", sa.String(), nullable=False),
        sa.Column("ou_id", UUID(as_uuid=True), nullable=True),
        sa.Column("agent_id", UUID(as_uuid=True), nullable=True),
        sa.Column("host_group_id", UUID(as_uuid=True), nullable=True),
        sa.Column("conditions", JSONB(astext_type=sa.Text()), nullable=False, server_default="{}"),
        sa.Column("parameters", JSONB(astext_type=sa.Text()), nullable=False, server_default="{}"),
        sa.Column("priority", sa.Integer(), nullable=False, server_default="100"),
        sa.Column("link_order", sa.Integer(), nullable=False, server_default="100"),
        sa.Column("enforced", sa.Boolean(), nullable=False, server_default=sa.text("false")),
        sa.Column("enabled", sa.Boolean(), nullable=False, server_default=sa.text("true")),
        sa.Column("auto_apply", sa.Boolean(), nullable=False, server_default=sa.text("false")),
        sa.Column("require_approval", sa.Boolean(), nullable=False, server_default=sa.text("true")),
        sa.Column("created_by", sa.String(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.ForeignKeyConstraint(["tenant_id"], ["tenants.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["plan_id"], ["orchestration_plans.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["ou_id"], ["ou_nodes.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["agent_id"], ["agents.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["host_group_id"], ["host_groups.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.CheckConstraint(
            "target_type IN ('ou', 'host', 'group', 'label_selector', 'global')",
            name="ck_orchestration_plan_links_target_type",
        ),
    )

    op.create_table(
        "compiled_host_state",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), nullable=False),
        sa.Column("tenant_id", UUID(as_uuid=True), nullable=False),
        sa.Column("agent_id", UUID(as_uuid=True), nullable=False),
        sa.Column("generation", sa.BigInteger(), nullable=False),
        sa.Column("config_hash", sa.String(), nullable=False),
        sa.Column("state", JSONB(astext_type=sa.Text()), nullable=False, server_default="{}"),
        sa.Column("explain", JSONB(astext_type=sa.Text()), nullable=False, server_default="{}"),
        sa.Column("is_current", sa.Boolean(), nullable=False, server_default=sa.text("true")),
        sa.Column("compiled_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.ForeignKeyConstraint(["tenant_id"], ["tenants.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["agent_id"], ["agents.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("tenant_id", "agent_id", "generation", name="uq_compiled_host_state_agent_generation"),
    )
    # At most one current generation per host (partial unique index — the
    # generation history rows all carry is_current=false).
    op.create_index(
        "uq_compiled_host_state_current",
        "compiled_host_state",
        ["tenant_id", "agent_id"],
        unique=True,
        postgresql_where=sa.text("is_current"),
    )

    # Additive agents columns. tenant_id gets a DB-level server_default of
    # the seeded default tenant — so every future INSERT (enroll.go, tests,
    # anything) is automatically tenant-scoped without any application code
    # having to change; existing rows are then explicitly backfilled since
    # server_default only applies going forward. ou_id stays nullable with
    # no default (unassigned/root, the AD-model "not placed yet" state).
    op.add_column(
        "agents",
        sa.Column("tenant_id", UUID(as_uuid=True), nullable=True, server_default=sa.text(f"'{DEFAULT_TENANT_ID}'::uuid")),
    )
    op.add_column("agents", sa.Column("ou_id", UUID(as_uuid=True), nullable=True))
    op.execute(
        f"UPDATE agents SET tenant_id = '{DEFAULT_TENANT_ID}'::uuid WHERE tenant_id IS NULL"
    )
    op.create_foreign_key(
        "fk_agents_tenant_id", "agents", "tenants", ["tenant_id"], ["id"], ondelete="SET NULL"
    )
    op.create_foreign_key(
        "fk_agents_ou_id", "agents", "ou_nodes", ["ou_id"], ["id"], ondelete="SET NULL"
    )


def downgrade() -> None:
    op.drop_constraint("fk_agents_ou_id", "agents", type_="foreignkey")
    op.drop_constraint("fk_agents_tenant_id", "agents", type_="foreignkey")
    op.drop_column("agents", "ou_id")
    op.drop_column("agents", "tenant_id")
    op.drop_index("uq_compiled_host_state_current", table_name="compiled_host_state")
    op.drop_table("compiled_host_state")
    op.drop_table("orchestration_plan_links")
    op.drop_table("orchestration_plan_versions")
    op.drop_table("orchestration_plans")
    op.drop_table("host_group_members")
    op.drop_table("host_groups")
    op.drop_table("ou_nodes")
    op.drop_table("tenants")
