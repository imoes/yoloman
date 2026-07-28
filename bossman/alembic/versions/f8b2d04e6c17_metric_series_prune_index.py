"""index metric_series(metric) for the process-series prune

Clearing the backlog took 40 minutes for 40,592 series (84 batches, ~29 s each). The
prune's candidate query filters `metric IN ('process_cpu_percent','process_rss_bytes')`
and metric_series had no index on `metric`, so every batch re-scanned the dimension
table (~96k rows at the time) before the two NOT EXISTS probes.

On a healthy DB with `process_metric_stale_minutes = 1` the backlog never builds and
each run prunes only a handful, so this is about staying fast when something has
stalled — exactly the situation the index is for.

Revision ID: f8b2d04e6c17
Revises: e7a1c93b5d21
"""
from alembic import op

revision = "f8b2d04e6c17"
down_revision = "e7a1c93b5d21"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_index("ix_metric_series_metric", "metric_series", ["metric"])


def downgrade() -> None:
    op.drop_index("ix_metric_series_metric", table_name="metric_series")
