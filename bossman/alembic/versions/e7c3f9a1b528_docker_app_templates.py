"""docker_app_templates — Docker containers with README-extracted variables

The app store's docker counterpart: a container image with its configurable
variables (env → templating params), ports and volumes, extracted from the
image's Docker Hub README via an LLM.

Revision ID: e7c3f9a1b528
Revises: d5b1e0a7c246
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision = "e7c3f9a1b528"
down_revision = "d5b1e0a7c246"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "docker_app_templates",
        sa.Column("id", postgresql.UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), primary_key=True),
        sa.Column("tenant_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("image", sa.String(), nullable=False),
        sa.Column("name", sa.String(), nullable=False, server_default=""),
        sa.Column("description", sa.Text(), nullable=False, server_default=""),
        sa.Column("variables", postgresql.JSONB(astext_type=sa.Text()), nullable=False, server_default=sa.text("'[]'::jsonb")),
        sa.Column("ports", postgresql.JSONB(astext_type=sa.Text()), nullable=False, server_default=sa.text("'[]'::jsonb")),
        sa.Column("volumes", postgresql.JSONB(astext_type=sa.Text()), nullable=False, server_default=sa.text("'[]'::jsonb")),
        sa.Column("popularity", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("readme_hash", sa.String(), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("image", name="uq_docker_app_templates_image"),
    )


def downgrade() -> None:
    op.drop_table("docker_app_templates")
