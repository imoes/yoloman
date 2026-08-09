"""restore metrics_raw compress_after to 1 day — the operator's setting, not mine

Reverting my own change. The original value from d1c5b7e9a2f4 was 1 day; a3f7c1e58b04 moved it to 8 h
and b5e2d7a91c36 to 4 h, both in commit 1fa150fc, and neither was asked for. The operator's instruction
is that metrics_raw compresses after 1 day.

What that costs, stated plainly so the trade is visible rather than buried: compression starts a day
after a chunk closes instead of four hours, so the uncompressed window grows from ~8 h to ~28 h. On this
fleet the uncompressed working set is ~50 MB per 4-hour chunk, so expect roughly 350 MB instead of
~100 MB in metrics_raw. That was the whole reason I had tightened it — the uncompressed window, not the
compressed history, is where the size sits (measured: 4 months of history costs ~22 MB).

Why 1 day is nonetheless a sound setting, which is worth recording so nobody "fixes" it again:

* It is well clear of every constraint. The aggregate refresh policies use start_offset 3 h for
  cagg_metrics_5min and cagg_metrics_hourly, and a refresh rewriting rows inside a compressed chunk is
  the expensive case — 1 day leaves that untouched by a wide margin, where 4 h merely also cleared it.
* Backfill is safer. The agent keeps 24 h of raw samples, so a host offline for a day delivers the
  backlog on reconnect. INSERT into a compressed chunk is supported (it lands in the uncompressed part),
  but at compress_after 1 day that backlog mostly arrives before compression rather than after.
* A DELETE against a compressed chunk decompresses it, and the pages only come back with VACUUM FULL
  (see docs/metrics-storage.md). A longer uncompressed window means routine maintenance touches
  compressed chunks less often.

chunk_time_interval stays at 4 hours (also changed by a3f7c1e58b04). Left deliberately: with
compress_after 1 day, finer chunks mean LESS uncompressed data at the margin and better chunk exclusion,
so it works in favour of the 1-day setting rather than against it. Say the word and it goes back to 1 day
too.

cagg_metrics_5min is not touched: b5e2d7a91c36 set it to 1 day, which is what d1c5b7e9a2f4 had.

Revision ID: f4a7b2c8d519
Revises: e5c1a8b46d92
"""
from alembic import op

revision = "f4a7b2c8d519"
down_revision = "e5c1a8b46d92"
branch_labels = None
depends_on = None


def _set_compress_after(table: str, after: str) -> None:
    # remove + add, matching b5e2d7a91c36: there is no ALTER for a policy's config.
    op.execute(f"SELECT remove_compression_policy('{table}', if_exists => true)")
    op.execute(f"SELECT add_compression_policy('{table}', compress_after => INTERVAL '{after}')")


def upgrade() -> None:
    _set_compress_after("metrics_raw", "1 day")


def downgrade() -> None:
    # Back to what b5e2d7a91c36 left, not to the original — a downgrade undoes THIS revision only.
    _set_compress_after("metrics_raw", "4 hours")
