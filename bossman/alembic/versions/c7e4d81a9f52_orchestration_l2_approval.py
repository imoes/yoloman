"""policy/orchestration L2: approval gate + global YOLO-MAN mode switch

Revision ID: c7e4d81a9f52
Revises: b3f1a2c9d740
Create Date: 2026-07-08

Block L2 wires up the `require_approval`/`auto_apply` columns L1 already
added to `orchestration_plan_links` but never enforced anywhere: a link is
now created with a `status` of `pending_approval` (safe default) unless
`auto_apply` is set or `require_approval` is false, in which case it goes
straight to `active`. Only `active` links are picked up by
services/compiler.py's assignment resolution — a pending link has no
effect on any host's compiled desired state until a human approves it via
`POST /api/v1/orchestration/plans/{id}/links/{id}/approve`. The MCP write
tool can never set `auto_apply=true` itself (only the human-authenticated
REST API can) — see services/compiler.py's docstring and
bossman/mcp/server.py's new Block L2 tool section.

On top of that per-link gate, `system_settings` adds one global override
switch: "YOLO-MAN mode" (the project's own namesake — "You Only Look
Once"). When enabled, every new link is created `active` immediately
regardless of its own require_approval/auto_apply values — a deliberate,
explicit, human-only (never MCP-settable) master switch mirroring the
Auto-vs-Manual mode distinction the user asked for, analogous to Claude
Code's own auto/manual mode toggle. Off (the seeded default) is the safe,
approval-required posture; the user has explicitly asked to turn it on for
this instance after this migration lands (done via the REST toggle, not
hardcoded into the seed, so a fresh install always starts safe).
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = "c7e4d81a9f52"
down_revision: Union[str, Sequence[str], None] = "b3f1a2c9d740"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

# Fixed, well-known id for the one-and-only system_settings row — same
# "deterministic singleton" convention as the L1 default tenant.
SYSTEM_SETTINGS_ID = "00000000-0000-0000-0000-0000000000f1"


def upgrade() -> None:
    op.add_column(
        "orchestration_plan_links",
        sa.Column("status", sa.String(), nullable=False, server_default="pending_approval"),
    )
    op.create_check_constraint(
        "ck_orchestration_plan_links_status",
        "orchestration_plan_links",
        "status IN ('pending_approval', 'active', 'rejected')",
    )
    # Existing links (created before this migration, back when every link
    # applied immediately) keep behaving exactly as before — backfill them
    # to active rather than silently pending_approval-ing them out of the
    # compiled state on the next compile.
    op.execute("UPDATE orchestration_plan_links SET status = 'active' WHERE status = 'pending_approval'")

    op.create_table(
        "system_settings",
        sa.Column("id", UUID(as_uuid=True), nullable=False),
        sa.Column("yolo_mode", sa.Boolean(), nullable=False, server_default=sa.text("false")),
        sa.Column("updated_by", sa.String(), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.PrimaryKeyConstraint("id"),
    )
    op.execute(f"INSERT INTO system_settings (id, yolo_mode) VALUES ('{SYSTEM_SETTINGS_ID}'::uuid, false)")


def downgrade() -> None:
    op.drop_table("system_settings")
    op.drop_constraint("ck_orchestration_plan_links_status", "orchestration_plan_links", type_="check")
    op.drop_column("orchestration_plan_links", "status")
