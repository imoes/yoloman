"""custom multi-host graphs (Block K11)

Revision ID: 5e81d459a395
Revises: a8a5640a2963
Create Date: 2026-07-08

Zabbix gap-analysis Block K11: a saved, reusable chart combining items
from several hosts (unlike the dashboard's per-widget series, which are
built ad hoc). `graphs` is the chart's own options; `graph_items` are its
member series, each pinned to one agent+metric with its own color/draw
style/axis/function.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = "5e81d459a395"
down_revision: Union[str, Sequence[str], None] = "a8a5640a2963"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "graphs",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), nullable=False),
        sa.Column("name", sa.String(), nullable=False),
        sa.Column("graph_type", sa.String(), nullable=False, server_default="normal"),
        sa.Column("y_axis_mode", sa.String(), nullable=False, server_default="calculated"),
        sa.Column("show_legend", sa.Boolean(), nullable=False, server_default="true"),
        sa.Column("show_working_time", sa.Boolean(), nullable=False, server_default="false"),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("name", name="uq_graphs_name"),
        sa.CheckConstraint("graph_type IN ('normal', 'stacked')", name="ck_graphs_graph_type"),
    )
    op.create_table(
        "graph_items",
        sa.Column("id", UUID(as_uuid=True), server_default=sa.text("gen_random_uuid()"), nullable=False),
        sa.Column("graph_id", UUID(as_uuid=True), nullable=False),
        sa.Column("agent_id", UUID(as_uuid=True), nullable=False),
        sa.Column("metric", sa.String(), nullable=False),
        sa.Column("label", sa.String(), nullable=True),
        sa.Column("color", sa.String(), nullable=False, server_default="#1e9600"),
        sa.Column("draw_style", sa.String(), nullable=False, server_default="line"),
        sa.Column("axis_side", sa.String(), nullable=False, server_default="left"),
        sa.Column("function", sa.String(), nullable=False, server_default="avg"),
        sa.Column("sort_order", sa.Integer(), nullable=False, server_default="0"),
        sa.ForeignKeyConstraint(["graph_id"], ["graphs.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["agent_id"], ["agents.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.CheckConstraint("draw_style IN ('line', 'bold_line', 'filled', 'dot', 'dashed', 'gradient')", name="ck_graph_items_draw_style"),
        sa.CheckConstraint("axis_side IN ('left', 'right')", name="ck_graph_items_axis_side"),
        sa.CheckConstraint("function IN ('avg', 'min', 'max', 'last')", name="ck_graph_items_function"),
    )
    op.create_index("idx_graph_items_graph", "graph_items", ["graph_id", "sort_order"])


def downgrade() -> None:
    op.drop_index("idx_graph_items_graph", table_name="graph_items")
    op.drop_table("graph_items")
    op.drop_table("graphs")
