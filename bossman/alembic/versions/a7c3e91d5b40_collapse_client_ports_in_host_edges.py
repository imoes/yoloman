"""collapse client ports in host_edges

The poller now folds proven client ports into one edge per (comm, addr) before writing
(services/edge_identity.py). This applies the same rule ONCE to what the old keying already accrued: on this
fleet 70 841 of 73 235 rows (84 MB) were single-connection edges to a peer's random high port, and the table
had no retention, so they were permanent.

The rule is unchanged and takes its evidence from the rows themselves: within one agent's set, a port at or
above the ephemeral floor that is ONE OF EIGHT OR MORE at the same address is a client port. A service does
not live on eight random high ports of one address. Ports below the floor, and small high-port groups
(mysqlx on 33060 and friends), are not touched.

Nothing is discarded: the collapsed row carries the SUMMED event count, the earliest first_seen_at, the
latest last_seen_at, and the busiest member's dst_agent_id and latency. `GET /relationships` already grouped
these away at read time, so no display changes — only the table stops growing without bound.

Irreversible by nature: the individual ports are what the rule declares meaningless, so they cannot be
reconstructed. The downgrade is therefore a no-op rather than a lie, and the source of truth (each agent's
own connection_edges, 24h) refills anything still live on the next poll.

Revision ID: a7c3e91d5b40
Revises: f2b6d0c48a17
"""

from alembic import op

revision = "a7c3e91d5b40"
down_revision = "f2b6d0c48a17"
branch_labels = None
depends_on = None

EPHEMERAL_FLOOR = 32768
CLIENT_PORT_QUORUM = 8

_COLLAPSE = f"""
WITH client_groups AS (
    SELECT src_agent_id, src_comm, dst_addr
    FROM host_edges
    WHERE dst_port >= {EPHEMERAL_FLOOR}
    GROUP BY src_agent_id, src_comm, dst_addr
    HAVING count(DISTINCT dst_port) >= {CLIENT_PORT_QUORUM}
),
folded AS (
    SELECT e.src_agent_id, e.src_comm, e.dst_addr,
           sum(e.event_count)                                                    AS event_count,
           min(e.first_seen_at)                                                   AS first_seen_at,
           max(e.last_seen_at)                                                    AS last_seen_at,
           (array_agg(e.dst_agent_id   ORDER BY e.event_count DESC))[1]           AS dst_agent_id,
           (array_agg(e.latency_ms_p50 ORDER BY e.event_count DESC))[1]           AS latency_ms_p50,
           (array_agg(e.latency_ms_p99 ORDER BY e.event_count DESC))[1]           AS latency_ms_p99
    FROM host_edges e
    JOIN client_groups g
      ON g.src_agent_id = e.src_agent_id AND g.src_comm = e.src_comm AND g.dst_addr = e.dst_addr
    WHERE e.dst_port >= {EPHEMERAL_FLOOR}
    GROUP BY e.src_agent_id, e.src_comm, e.dst_addr
),
gone AS (
    DELETE FROM host_edges e
    USING client_groups g
    WHERE g.src_agent_id = e.src_agent_id AND g.src_comm = e.src_comm AND g.dst_addr = e.dst_addr
      AND e.dst_port >= {EPHEMERAL_FLOOR}
    RETURNING 1
)
INSERT INTO host_edges (src_agent_id, src_comm, dst_addr, dst_port, dst_agent_id, event_count,
                        first_seen_at, last_seen_at, latency_ms_p50, latency_ms_p99)
SELECT src_agent_id, src_comm, dst_addr, 0, dst_agent_id, event_count,
       first_seen_at, last_seen_at, latency_ms_p50, latency_ms_p99
FROM folded
ON CONFLICT (src_agent_id, src_comm, dst_addr, dst_port) DO UPDATE SET
    event_count   = host_edges.event_count + excluded.event_count,
    first_seen_at = least(host_edges.first_seen_at, excluded.first_seen_at),
    last_seen_at  = greatest(host_edges.last_seen_at, excluded.last_seen_at)
"""


def upgrade() -> None:
    op.execute(_COLLAPSE)


def downgrade() -> None:
    # The per-connection ports are exactly what the rule declares meaningless; there is nothing to restore
    # them from. A no-op is the honest downgrade.
    pass
