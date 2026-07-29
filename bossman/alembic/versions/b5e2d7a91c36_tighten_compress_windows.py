"""tighten the uncompressed windows now that the real ratio is known

Measuring an actual chunk gave 37.3x (89 MB → 2456 kB), not the 8x I had assumed —
metrics_raw is (time, series_id, value) segmented by series_id, which is close to
ideal for columnar compression. That changes where the cost sits: after
a3f7c1e58b04 the projection was 113 MB/host, of which 352 of 454 MB (78%) was simply
the still-UNCOMPRESSED window of each tier, not the compressed history.

So shrink those windows:
    metrics_raw        compress_after 8 h → 4 h   (uncompressed window 12 h → 8 h)
    cagg_metrics_5min  compress_after 2 d → 1 d   (window ~3 d → ~2 d)

Two things bound how eager this may be:

1. BACKFILL. The agent keeps 24 h of raw samples (internal/config: Collect raw
   retention 24 h), so a host unreachable for a day delivers a day of backlog on
   reconnect, landing in chunks that are already compressed. TimescaleDB supports
   INSERT into a compressed chunk (it writes to the uncompressed part), so this is
   tolerable — and note it is equally true of 8 h and 4 h, since both are far below
   24 h. The choice between them is therefore about size, not safety.

2. AGGREGATE REFRESH, which is the real limit and why the tiers differ. A refresh
   policy REWRITES materialized rows inside its start_offset, and rewriting rows in a
   compressed chunk is the operation that hurts. Offsets here: 5min and hourly use
   start_offset 3 h, daily uses 7 DAYS. So 5min may compress after a day, while the
   daily aggregate must not be compressed inside a week — its 10-day chunks with
   compress_after 1 day only become eligible ~11 days in, which is already safe and is
   left alone.

Revision ID: b5e2d7a91c36
Revises: a3f7c1e58b04
"""
from alembic import op

revision = "b5e2d7a91c36"
down_revision = "a3f7c1e58b04"
branch_labels = None
depends_on = None


def _recompress(table: str, after: str) -> None:
    op.execute(f"SELECT remove_compression_policy('{table}', if_exists => true)")
    op.execute(f"SELECT add_compression_policy('{table}', compress_after => INTERVAL '{after}')")


def upgrade() -> None:
    _recompress("metrics_raw", "4 hours")
    _recompress("cagg_metrics_5min", "1 day")


def downgrade() -> None:
    _recompress("metrics_raw", "8 hours")
    _recompress("cagg_metrics_5min", "2 days")
