"""size chunks so compression actually gets a window before retention drops them

Measured on a live DB with 14 h of data: 258 MB, and BOTH metrics_raw chunks
uncompressed even though the compression job ran successfully (05:28, zero failures).
The policy was never wrong — the chunk was never eligible.

TimescaleDB compresses a chunk once the chunk's END is older than compress_after. With

    metrics_raw:  chunk_interval 1 day, compress_after 1 day, retention 2 days

a chunk covering 07-28 00:00 → 07-29 00:00 only becomes eligible after 07-30 00:00 —
which is when retention drops it too. Compression and deletion fall due at the same
moment, so raw data lives uncompressed for its entire life. Same trap, worse, on the
5-minute aggregate: chunk_interval 10 days with retention 10 days means ONE chunk
covering the whole window, which can never be compressed before it is dropped.

Fix: make chunks small relative to their retention.

    metrics_raw        4 h chunks, compress after 8 h   → ~10 of 12 chunks compressed
    cagg_metrics_5min  1 d chunks, compress after 2 d   → ~8 of 10 days compressed

hourly (10 d chunks / 90 d retention) and daily (10 d / 365 d) already have room, so
their policies stay as they are.

set_chunk_time_interval only affects chunks created FROM NOW ON; the two existing
oversized chunks age out on their own.

NOT changed, and deliberately: the `time DESC` index. It looked redundant next to the
PK (series_id, time), but pg_stat_all_indexes says otherwise — 5,177 scans reading
161 M tuples in 14 h, mostly the continuous-aggregate refresh scanning by bucket.
Dropping it would have traded 24 MB for a much slower refresh.

Revision ID: a3f7c1e58b04
Revises: f8b2d04e6c17
"""
from alembic import op

revision = "a3f7c1e58b04"
down_revision = "f8b2d04e6c17"
branch_labels = None
depends_on = None


def _recompress(table: str, after: str) -> None:
    """Replace a compression policy — remove_compression_policy is idempotent-ish
    (if_exists), so this is safe on a DB where the policy was already dropped."""
    op.execute(f"SELECT remove_compression_policy('{table}', if_exists => true)")
    op.execute(f"SELECT add_compression_policy('{table}', compress_after => INTERVAL '{after}')")


def upgrade() -> None:
    # raw: 4-hour chunks, compressed 8 hours after a chunk closes
    op.execute("SELECT set_chunk_time_interval('metrics_raw', INTERVAL '4 hours')")
    _recompress("metrics_raw", "8 hours")

    # 5-minute aggregate: daily chunks so its 10-day window holds ~10 chunks
    op.execute("SELECT set_chunk_time_interval('cagg_metrics_5min', INTERVAL '1 day')")
    _recompress("cagg_metrics_5min", "2 days")


def downgrade() -> None:
    op.execute("SELECT set_chunk_time_interval('metrics_raw', INTERVAL '1 day')")
    _recompress("metrics_raw", "1 day")
    op.execute("SELECT set_chunk_time_interval('cagg_metrics_5min', INTERVAL '10 days')")
    _recompress("cagg_metrics_5min", "1 day")
