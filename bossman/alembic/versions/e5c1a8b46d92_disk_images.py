"""Bare-metal deployment: disk_images + restore_jobs

Revision ID: e5c1a8b46d92
Revises: d2a8f6b3c471

A captured golden image and the machines being installed from it. See services/imaging.py for the
manifest's shape and why it is versioned.

Two constraints carry real weight:

`restore_jobs` is keyed by target **MAC**, not by agent — the target has no agent yet, which is the
entire point, and when it PXE-boots the only identity it can offer is its hardware address. The
`agent_id` column is filled in later, once the installed machine enrols, so the job stays linked to
what it produced.

The partial unique index allows only ONE pending-or-running job per MAC. Two concurrent installs
onto the same machine would race for its disk and the loser would find a half-written one; a
partial index says that in the schema instead of hoping the API remembers to check.
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "e5c1a8b46d92"
down_revision = "d2a8f6b3c471"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "disk_images",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")),
        sa.Column("name", sa.String(), nullable=False, unique=True),
        sa.Column("description", sa.Text(), nullable=False, server_default=""),
        sa.Column("source_agent_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("status", sa.String(), nullable=False, server_default="capturing"),
        sa.Column("manifest", postgresql.JSONB(), nullable=False, server_default="{}"),
        sa.Column("files", postgresql.JSONB(), nullable=False, server_default="{}"),
        sa.Column("error", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        # SET NULL, not CASCADE: deleting the source host must not delete images built from it —
        # outliving its source is what makes it a golden image.
        sa.ForeignKeyConstraint(["source_agent_id"], ["agents.id"], ondelete="SET NULL"),
        sa.CheckConstraint("status IN ('capturing', 'ready', 'failed')", name="ck_disk_images_status"),
    )
    op.create_table(
        "restore_jobs",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")),
        sa.Column("image_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("target_mac", sa.String(), nullable=False),
        sa.Column("target_hostname", sa.String(), nullable=False),
        sa.Column("target_disk", sa.String(), nullable=True),
        sa.Column("status", sa.String(), nullable=False, server_default="pending"),
        sa.Column("steps", postgresql.JSONB(), nullable=False, server_default="[]"),
        sa.Column("step_index", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("log", sa.Text(), nullable=False, server_default=""),
        sa.Column("error", sa.Text(), nullable=True),
        sa.Column("agent_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("now()")),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("finished_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["image_id"], ["disk_images.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["agent_id"], ["agents.id"], ondelete="SET NULL"),
        sa.CheckConstraint(
            "status IN ('pending', 'running', 'done', 'failed', 'cancelled')",
            name="ck_restore_jobs_status",
        ),
    )
    # The helper looks itself up by MAC on every checkin, so this is the hot path.
    op.create_index("ix_restore_jobs_mac", "restore_jobs", ["target_mac"])
    op.create_index(
        "uq_restore_jobs_active_mac",
        "restore_jobs",
        ["target_mac"],
        unique=True,
        postgresql_where=sa.text("status IN ('pending', 'running')"),
    )


def downgrade() -> None:
    op.drop_index("uq_restore_jobs_active_mac", table_name="restore_jobs")
    op.drop_index("ix_restore_jobs_mac", table_name="restore_jobs")
    op.drop_table("restore_jobs")
    op.drop_table("disk_images")
