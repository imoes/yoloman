"""metrics_daily continuous aggregate + long-term retention (Block K1b)

Revision ID: cd09bed433e7
Revises: e6a3c9d02f14
Create Date: 2026-07-07

Zabbix gap-analysis finding: `metrics_hourly` (the initial schema's
continuous aggregate) already exists but (a) was never read by any query
in the codebase and (b) had no retention policy of its own, so it grew
unbounded while raw `metrics` still only lived 14 days — a graph older
than 14 days silently returned nothing even though the hourly averages
were sitting right there, unused. This migration adds the missing second
tier (`metrics_daily`, CheckMK-RRD-style long-term downsampled history)
and gives both continuous aggregates an explicit, bounded retention:
hourly for 90 days, daily for 365 days — read by
services/metrics_query.py's tiered resolution picker.
"""

from typing import Sequence, Union

from alembic import op

revision: str = "cd09bed433e7"
down_revision: Union[str, Sequence[str], None] = "e6a3c9d02f14"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # WITH NO DATA: see f17d664762b0's identical note — CREATE MATERIALIZED
    # VIEW ... WITH DATA cannot run inside Alembic's transaction block; the
    # continuous aggregate policy below refreshes it on its own schedule.
    op.execute("""
        CREATE MATERIALIZED VIEW metrics_daily
        WITH (timescaledb.continuous) AS
        SELECT time_bucket('1 day', time) AS bucket,
               agent_id, metric, labels,
               avg(value) AS avg_value, max(value) AS max_value, min(value) AS min_value
        FROM metrics
        GROUP BY bucket, agent_id, metric, labels
        WITH NO DATA
    """)
    op.execute("""
        SELECT add_continuous_aggregate_policy('metrics_daily',
            start_offset => INTERVAL '3 days',
            end_offset => INTERVAL '1 day',
            schedule_interval => INTERVAL '1 day')
    """)
    op.execute("SELECT add_retention_policy('metrics_hourly', INTERVAL '90 days')")
    op.execute("SELECT add_retention_policy('metrics_daily', INTERVAL '365 days')")


def downgrade() -> None:
    op.execute("SELECT remove_retention_policy('metrics_daily', if_exists => true)")
    op.execute("SELECT remove_retention_policy('metrics_hourly', if_exists => true)")
    op.execute("DROP MATERIALIZED VIEW IF EXISTS metrics_daily")
