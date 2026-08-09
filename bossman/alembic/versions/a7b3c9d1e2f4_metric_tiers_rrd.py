"""RRD-style metric downsampling tiers (Checkmk RRA-equivalent)

Reshape the metric history into Checkmk-RRD-style tiers so storage stays
bounded at fleet scale instead of growing linearly with hosts:

  raw `metrics`      30s   2 days    (full resolution — Checkmk keeps 2d too)
  metrics_5min       5min  10 days
  metrics_hourly     1h    90 days
  metrics_daily      1d    365 days

Two structural changes make raw=2d safe:
  * raw uses 1-day chunks (set_chunk_time_interval) so the 2-day retention can
    actually drop day-old chunks (weekly chunks couldn't).
  * metrics_daily is rebuilt to cascade FROM metrics_hourly (not raw), so raw
    only has to survive long enough to feed the 5-min/hourly tiers.

Idempotent (IF EXISTS / if_not_exists) because the live DB already had these
applied by hand; a fresh deploy gets the same shape.

Revision ID: a7b3c9d1e2f4
Revises: e2f3a4b5c6d7
Create Date: 2026-07-22
"""

from alembic import op

revision = "a7b3c9d1e2f4"
down_revision = "e2f3a4b5c6d7"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # CAgg DDL (CREATE MATERIALIZED VIEW ... timescaledb.continuous) cannot run
    # inside a transaction block, so escape alembic's per-migration transaction.
    with op.get_context().autocommit_block():
        # raw: 1-day chunks + 2-day retention (was weekly chunks / 14 days)
        op.execute("SELECT set_chunk_time_interval('metrics', INTERVAL '1 day')")
        op.execute("SELECT remove_retention_policy('metrics', if_exists => true)")
        op.execute("SELECT add_retention_policy('metrics', INTERVAL '2 days', if_not_exists => true)")

        # 5-minute tier (Checkmk RRA 5min/10d equivalent)
        op.execute(
            """
            CREATE MATERIALIZED VIEW IF NOT EXISTS metrics_5min
            WITH (timescaledb.continuous) AS
            SELECT time_bucket('5 minutes', time) AS bucket,
                   agent_id, metric, labels,
                   avg(value) AS avg_value, max(value) AS max_value, min(value) AS min_value
            FROM metrics
            GROUP BY bucket, agent_id, metric, labels
            WITH NO DATA
            """
        )
        op.execute(
            """
            SELECT add_continuous_aggregate_policy('metrics_5min',
                start_offset => INTERVAL '3 hours', end_offset => INTERVAL '10 minutes',
                schedule_interval => INTERVAL '15 minutes', if_not_exists => true)
            """
        )
        op.execute("SELECT add_retention_policy('metrics_5min', INTERVAL '10 days', if_not_exists => true)")

        # metrics_daily cascades from metrics_hourly (was: from raw metrics with
        # a 3-day refresh lookback, which is incompatible with raw=2d).
        op.execute("DROP MATERIALIZED VIEW IF EXISTS metrics_daily")
        op.execute(
            """
            CREATE MATERIALIZED VIEW metrics_daily
            WITH (timescaledb.continuous) AS
            SELECT time_bucket('1 day', bucket) AS bucket,
                   agent_id, metric, labels,
                   avg(avg_value) AS avg_value, max(max_value) AS max_value, min(min_value) AS min_value
            FROM metrics_hourly
            GROUP BY 1, agent_id, metric, labels
            WITH NO DATA
            """
        )
        op.execute(
            """
            SELECT add_continuous_aggregate_policy('metrics_daily',
                start_offset => INTERVAL '7 days', end_offset => INTERVAL '1 day',
                schedule_interval => INTERVAL '1 day', if_not_exists => true)
            """
        )
        op.execute("SELECT add_retention_policy('metrics_daily', INTERVAL '365 days', if_not_exists => true)")

        # Columnstore compression on every tier — without it these tables store
        # ~500 bytes/row (metric name + labels JSON + row header + indexes); with
        # segmentby (agent_id, metric) the repeated identifiers dedupe away and
        # values delta-compress, measured at ~19-60x. Compress chunks after 1 day
        # (once they stop receiving writes). Applies to raw + all rollups.
        op.execute(
            "ALTER TABLE metrics SET (timescaledb.enable_columnstore = true, "
            "timescaledb.segmentby = 'agent_id, metric', timescaledb.orderby = 'time DESC')"
        )
        op.execute("SELECT add_compression_policy('metrics', INTERVAL '1 day', if_not_exists => true)")
        for view in ("metrics_5min", "metrics_hourly", "metrics_daily"):
            op.execute(
                f"ALTER MATERIALIZED VIEW {view} SET (timescaledb.enable_columnstore = true, "
                "timescaledb.segmentby = 'agent_id, metric', timescaledb.orderby = 'bucket DESC')"
            )
            op.execute(f"SELECT add_compression_policy('{view}', INTERVAL '1 day', if_not_exists => true)")


def downgrade() -> None:
    # One-way tier redesign; the previous 14-day raw / raw-sourced daily shape
    # is not restored (no callers depend on reversing it).
    pass
