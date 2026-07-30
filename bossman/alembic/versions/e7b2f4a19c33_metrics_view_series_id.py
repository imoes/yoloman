"""metrics view: expose series_id, so an ORM read can tell two label series apart

Revision ID: e7b2f4a19c33
Revises: d5a2c8b41f37

The `metrics` view re-joins metric_series onto metrics_raw and exposed
(time, agent_id, metric, value, labels) — deliberately, to keep every existing
`select(Metric)` read working after the series normalisation. What it did NOT expose is
the row's actual identity, `series_id`, and that turned out to matter a great deal.

The Metric ORM class is mapped onto this view with primary key (time, agent_id, metric).
The agent stamps every point of one sampling tick with the identical timestamp, so
vpp0221 writes its 5 disk mounts at exactly the same microsecond (verified: all five
disk_used_pct rows read 15:05:25.000000). Those five rows therefore share the mapped
primary key, and SQLAlchemy's identity map folded them into ONE object: `select(Metric)`
returned five results that were the same Python object five times, every one of them
reporting mount "/". `evaluate_host` builds a dict keyed by mount from that, so it saw a
single mount and 4 of vpp0221's 5 filesystems were never checked against a threshold
rule. A filling /var/lib/vz would not have warned. It looked monitored only because the
agent's own checks write services under the same names.

`labels` cannot simply join the key — a dict is unhashable and the identity map rejects
it. `series_id` is the right key anyway: together with `time` it is exactly metrics_raw's
own primary key, i.e. the true identity of the row.

Adding a column to a view is safe for readers here because every query names its columns
explicitly (SQLAlchemy emits no `SELECT *`).
"""

from alembic import op

revision = "e7b2f4a19c33"
down_revision = "d5a2c8b41f37"
branch_labels = None
depends_on = None

# CREATE OR REPLACE cannot add a column to an existing view in PostgreSQL ("cannot change
# name of view column" / column count), so the view is dropped and recreated. It holds no
# data — it is a join over metrics_raw and metric_series.
_NEW = """
CREATE VIEW metrics AS
SELECT r.time, r.series_id, s.agent_id, s.metric, r.value, s.labels
FROM metrics_raw r JOIN metric_series s ON s.series_id = r.series_id
"""

_OLD = """
CREATE VIEW metrics AS
SELECT r.time, s.agent_id, s.metric, r.value, s.labels
FROM metrics_raw r JOIN metric_series s ON s.series_id = r.series_id
"""


def upgrade() -> None:
    op.execute("DROP VIEW IF EXISTS metrics")
    op.execute(_NEW)


def downgrade() -> None:
    op.execute("DROP VIEW IF EXISTS metrics")
    op.execute(_OLD)
