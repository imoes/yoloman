"""blueprints table + provides/requires on docker_app_templates

A blueprint composes native + docker services wired by capability and compiles
to a typed playbook. Docker templates gain the same provides/requires capability
contract native roles carry, so both feed one matcher.

Revision ID: f1a9c4d70e83
Revises: e7c3f9a1b528
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision = "f1a9c4d70e83"
down_revision = "e7c3f9a1b528"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("docker_app_templates", sa.Column("provides", postgresql.JSONB(astext_type=sa.Text()), nullable=False, server_default=sa.text("'[]'::jsonb")))
    op.add_column("docker_app_templates", sa.Column("requires", postgresql.JSONB(astext_type=sa.Text()), nullable=False, server_default=sa.text("'[]'::jsonb")))
    op.create_table(
        "blueprints",
        sa.Column("id", postgresql.UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("tenant_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("description", sa.Text(), nullable=False, server_default=""),
        sa.Column("status", sa.String(), nullable=False, server_default="draft"),
        sa.Column("services", postgresql.JSONB(astext_type=sa.Text()), nullable=False, server_default=sa.text("'[]'::jsonb")),
        sa.Column("created_by", sa.String(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("tenant_id", "name", name="uq_blueprints_name"),
    )


def downgrade() -> None:
    op.drop_table("blueprints")
    op.drop_column("docker_app_templates", "requires")
    op.drop_column("docker_app_templates", "provides")
