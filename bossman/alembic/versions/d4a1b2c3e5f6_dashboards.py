"""unified named dashboards + dashboard_id on widgets

Introduces the `dashboards` table (Checkmk-style dashboard management) and
attaches every widget to a dashboard. Backfills:
  - one default "Fleet Overview" dashboard per user that owns widgets, and
    points those widgets at it;
  - each generated_dashboards (AI) blob becomes a source='ai' dashboard whose
    inline-data widget specs are materialized as dashboard_widgets rows (their
    `data` stored under config.static), so the AI dashboard is now a real,
    editable, persisted dashboard.
Also widens the widget_type check constraint to the full render set (the 8
extra types the AI can emit), and adds a JSONB `context` filter set on the
dashboard (used by Block B fleet filters).

Revision ID: d4a1b2c3e5f6
Revises: e1b2c3d4f5a6
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision = "d4a1b2c3e5f6"
down_revision = "e1b2c3d4f5a6"
branch_labels = None
depends_on = None

_ALL_TYPES = (
    "'top_hosts', 'problems', 'gauge', 'timeseries', 'donut', 'stat', "
    "'bar', 'table', 'status_tiles', 'progress', 'ai_summary', 'war_room', 'log', 'callout'"
)
_AI_TYPES_SQL = (
    "'top_hosts','problems','gauge','timeseries','donut','stat',"
    "'bar','table','status_tiles','progress','ai_summary','war_room','log','callout'"
)


def upgrade() -> None:
    op.create_table(
        "dashboards",
        sa.Column("id", UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")),
        sa.Column("username", sa.String(), nullable=False),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("is_default", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("source", sa.String(), nullable=False, server_default="manual"),
        sa.Column("prompt", sa.String(), nullable=False, server_default=""),
        sa.Column("context", JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("username", "name", name="uq_dashboards_username_name"),
    )
    op.create_index("idx_dashboards_username", "dashboards", ["username"])

    op.add_column("dashboard_widgets", sa.Column("dashboard_id", UUID(as_uuid=True), nullable=True))
    op.create_foreign_key(
        "fk_dashboard_widgets_dashboard", "dashboard_widgets", "dashboards",
        ["dashboard_id"], ["id"], ondelete="CASCADE",
    )
    op.create_index("idx_dashboard_widgets_dashboard", "dashboard_widgets", ["dashboard_id"])

    # Widen the widget-type constraint to the full render set.
    op.drop_constraint("ck_dashboard_widgets_type", "dashboard_widgets", type_="check")
    op.create_check_constraint("ck_dashboard_widgets_type", "dashboard_widgets", f"widget_type IN ({_ALL_TYPES})")

    # Backfill: a default dashboard per user that has widgets, then link them.
    op.execute(
        """
        INSERT INTO dashboards (username, name, is_default, source)
        SELECT DISTINCT username, 'Fleet Overview', true, 'manual'
        FROM dashboard_widgets
        ON CONFLICT (username, name) DO NOTHING
        """
    )
    op.execute(
        """
        UPDATE dashboard_widgets w
        SET dashboard_id = d.id
        FROM dashboards d
        WHERE d.username = w.username AND d.name = 'Fleet Overview' AND w.dashboard_id IS NULL
        """
    )

    # Backfill: each AI blob → a source='ai' dashboard + materialized widgets.
    op.execute(
        """
        INSERT INTO dashboards (username, name, is_default, source, prompt, created_at)
        SELECT username, 'AI Dashboard', false, 'ai', prompt, created_at
        FROM generated_dashboards
        WHERE jsonb_array_length(COALESCE(widgets, '[]'::jsonb)) > 0
        ON CONFLICT (username, name) DO NOTHING
        """
    )
    op.execute(
        f"""
        INSERT INTO dashboard_widgets
            (dashboard_id, username, widget_type, title, gs_x, gs_y, gs_w, gs_h, config, pinned, hidden)
        SELECT d.id, gd.username,
               spec->>'widget_type',
               COALESCE(spec->>'title', ''),
               COALESCE((spec->>'gs_x')::int, 0),
               COALESCE((spec->>'gs_y')::int, 0),
               COALESCE((spec->>'gs_w')::int, 4),
               COALESCE((spec->>'gs_h')::int, 3),
               jsonb_build_object('static', spec->'data'),
               false, false
        FROM generated_dashboards gd
        JOIN dashboards d ON d.username = gd.username AND d.source = 'ai' AND d.name = 'AI Dashboard'
        CROSS JOIN LATERAL jsonb_array_elements(COALESCE(gd.widgets, '[]'::jsonb)) AS spec
        WHERE spec->>'widget_type' IN ({_AI_TYPES_SQL})
        """
    )


def downgrade() -> None:
    # Drop AI-materialized widgets first so the narrowed constraint can reapply.
    op.execute(
        """
        DELETE FROM dashboard_widgets
        WHERE dashboard_id IN (SELECT id FROM dashboards WHERE source = 'ai')
        """
    )
    op.drop_constraint("ck_dashboard_widgets_type", "dashboard_widgets", type_="check")
    op.create_check_constraint(
        "ck_dashboard_widgets_type", "dashboard_widgets",
        "widget_type IN ('top_hosts', 'problems', 'gauge', 'timeseries', 'donut', 'stat')",
    )
    op.drop_index("idx_dashboard_widgets_dashboard", "dashboard_widgets")
    op.drop_constraint("fk_dashboard_widgets_dashboard", "dashboard_widgets", type_="foreignkey")
    op.drop_column("dashboard_widgets", "dashboard_id")
    op.drop_index("idx_dashboards_username", "dashboards")
    op.drop_table("dashboards")
