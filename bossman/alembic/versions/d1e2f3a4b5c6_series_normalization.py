"""series normalization: labels -> metric_series, metrics_raw(series_id)

Move the per-row `labels` jsonb out of the metrics hypertable into a small
`metric_series` dimension. The hypertable becomes `metrics_raw(time, series_id,
value)` with compression segmentby=series_id, so each compressed segment is a
single series (clean delta/gorilla compression) instead of many label-distinct
series interleaved (which capped compression at ~4.5x on high-cardinality-label
metrics). Compatibility VIEWS (metrics, metrics_5min/hourly/daily) re-join the
labels so every existing read path keeps its old shape.

This env applied the change directly via SQL against a freshly-truncated DB;
this migration reproduces it for other environments. Down-revision is the
metric-tiers head; the pre-existing second head (business_services) is
unaffected.

Revision ID: d1e2f3a4b5c6
Revises: a7b3c9d1e2f4
"""
from alembic import op

revision = "d1e2f3a4b5c6"
down_revision = "a7b3c9d1e2f4"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("DROP MATERIALIZED VIEW IF EXISTS metrics_daily CASCADE")
    op.execute("DROP MATERIALIZED VIEW IF EXISTS metrics_hourly CASCADE")
    op.execute("DROP MATERIALIZED VIEW IF EXISTS metrics_5min CASCADE")
    op.execute("DROP TABLE IF EXISTS metrics CASCADE")

    op.execute(
        """
        CREATE TABLE metric_series (
            series_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            agent_id   uuid NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
            metric     text NOT NULL,
            labels     jsonb NOT NULL DEFAULT '{}'::jsonb,
            UNIQUE (agent_id, metric, labels)
        )
        """
    )
    op.execute("CREATE INDEX idx_metric_series_agent_metric ON metric_series (agent_id, metric)")

    op.execute(
        """
        CREATE TABLE metrics_raw (
            time      timestamptz NOT NULL,
            series_id bigint NOT NULL REFERENCES metric_series(series_id) ON DELETE CASCADE,
            value     double precision NOT NULL,
            PRIMARY KEY (series_id, time)
        )
        """
    )
    op.execute("SELECT create_hypertable('metrics_raw', 'time', chunk_time_interval => INTERVAL '1 day')")

    for name, bucket, src in (
        ("cagg_metrics_5min", "5 minutes", "metrics_raw"),
        ("cagg_metrics_hourly", "1 hour", "metrics_raw"),
    ):
        op.execute(
            f"""
            CREATE MATERIALIZED VIEW {name} WITH (timescaledb.continuous) AS
            SELECT time_bucket('{bucket}', time) AS bucket, series_id,
                   avg(value) AS avg_value, max(value) AS max_value, min(value) AS min_value
            FROM {src} GROUP BY bucket, series_id WITH NO DATA
            """
        )
    op.execute(
        """
        CREATE MATERIALIZED VIEW cagg_metrics_daily WITH (timescaledb.continuous) AS
        SELECT time_bucket('1 day', bucket) AS bucket, series_id,
               avg(avg_value) AS avg_value, max(max_value) AS max_value, min(min_value) AS min_value
        FROM cagg_metrics_hourly GROUP BY 1, series_id WITH NO DATA
        """
    )

    op.execute(
        """
        CREATE VIEW metrics AS
        SELECT r.time, s.agent_id, s.metric, r.value, s.labels
        FROM metrics_raw r JOIN metric_series s ON s.series_id = r.series_id
        """
    )
    for view, cagg in (
        ("metrics_5min", "cagg_metrics_5min"),
        ("metrics_hourly", "cagg_metrics_hourly"),
        ("metrics_daily", "cagg_metrics_daily"),
    ):
        op.execute(
            f"""
            CREATE VIEW {view} AS
            SELECT c.bucket, s.agent_id, s.metric, s.labels, c.avg_value, c.max_value, c.min_value
            FROM {cagg} c JOIN metric_series s ON s.series_id = c.series_id
            """
        )

    op.execute(
        "ALTER TABLE metrics_raw SET (timescaledb.enable_columnstore = true, "
        "timescaledb.segmentby = 'series_id', timescaledb.orderby = 'time DESC')"
    )
    op.execute("SELECT add_compression_policy('metrics_raw', INTERVAL '1 day', if_not_exists => true)")
    op.execute("SELECT add_retention_policy('metrics_raw', INTERVAL '2 days', if_not_exists => true)")

    op.execute(
        "SELECT add_continuous_aggregate_policy('cagg_metrics_5min', "
        "start_offset => INTERVAL '3 hours', end_offset => INTERVAL '10 minutes', "
        "schedule_interval => INTERVAL '15 minutes', if_not_exists => true)"
    )
    op.execute(
        "SELECT add_continuous_aggregate_policy('cagg_metrics_hourly', "
        "start_offset => INTERVAL '3 hours', end_offset => INTERVAL '1 hour', "
        "schedule_interval => INTERVAL '1 hour', if_not_exists => true)"
    )
    op.execute(
        "SELECT add_continuous_aggregate_policy('cagg_metrics_daily', "
        "start_offset => INTERVAL '7 days', end_offset => INTERVAL '1 day', "
        "schedule_interval => INTERVAL '1 day', if_not_exists => true)"
    )
    op.execute("SELECT add_retention_policy('cagg_metrics_5min', INTERVAL '10 days', if_not_exists => true)")
    op.execute("SELECT add_retention_policy('cagg_metrics_hourly', INTERVAL '90 days', if_not_exists => true)")
    op.execute("SELECT add_retention_policy('cagg_metrics_daily', INTERVAL '365 days', if_not_exists => true)")
    for cagg in ("cagg_metrics_5min", "cagg_metrics_hourly", "cagg_metrics_daily"):
        op.execute(
            f"ALTER MATERIALIZED VIEW {cagg} SET (timescaledb.enable_columnstore = true, "
            "timescaledb.segmentby = 'series_id', timescaledb.orderby = 'bucket DESC')"
        )
        op.execute(f"SELECT add_compression_policy('{cagg}', INTERVAL '1 day', if_not_exists => true)")


def downgrade() -> None:
    # One-way: the labels-per-row shape is not reconstructed.
    raise NotImplementedError("series normalization is not reversible")
