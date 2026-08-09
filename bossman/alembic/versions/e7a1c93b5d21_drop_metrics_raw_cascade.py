"""drop ON DELETE CASCADE from metrics_raw.series_id

The cascade made pruning impossible. Deleting a `metric_series` row fires an RI
cascade DELETE against `metrics_raw`, and that statement carries NO time predicate,
so it reaches the compressed chunks; TimescaleDB then decompresses to satisfy it and
the statement aborts with

    tuple decompression limit exceeded — current limit: 100000,
    tuples decompressed: 4134419

Measured on the live DB: the decompressed count is IDENTICAL (4,134,419) for batches
of 10, 50, 100 and 250 ids — it does not scale with the batch, because from ~10 ids
the planner stops seeking segments and decompresses wholesale. A batch of 1 works.
So batching cannot fix it; the cascade itself has to go. Consequence of leaving it in
place: nothing was ever pruned (79,946 of 80,774 process series stale = 81% of all
cardinality) and the retries inline-decompressed a chunk to 1150 MB.

Without the cascade, deletion becomes two explicit steps that a hypertable can serve:
delete the points with `time >= <compress boundary>` (chunk exclusion keeps the
compressed chunks out of the statement), then delete the now point-less dimension row
as a plain-table DELETE. A series that still owns points in a compressed chunk is
simply refused by the FK — which is correct: it is not prunable yet, and it goes away
via the orphan sweep once retention drops its chunk.

`metric_series.agent_id → agents` keeps its cascade; that one points at a plain
table, not a hypertable, so it has no decompression problem.

Revision ID: e7a1c93b5d21
Revises: c1f0a4b7d2e9
"""
from alembic import op

revision = "e7a1c93b5d21"
down_revision = "c1f0a4b7d2e9"
branch_labels = None
depends_on = None

_FK = "metrics_raw_series_id_fkey"


def upgrade() -> None:
    op.drop_constraint(_FK, "metrics_raw", type_="foreignkey")
    # NO ACTION (the default): deleting a series that still owns points is refused
    # rather than silently cascading into compressed chunks.
    op.create_foreign_key(
        _FK, "metrics_raw", "metric_series",
        ["series_id"], ["series_id"],
    )


def downgrade() -> None:
    op.drop_constraint(_FK, "metrics_raw", type_="foreignkey")
    op.create_foreign_key(
        _FK, "metrics_raw", "metric_series",
        ["series_id"], ["series_id"], ondelete="CASCADE",
    )
