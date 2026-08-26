"""What makes two connections THE SAME relationship — and why a client port never does.

`host_edges` is keyed (src_comm, dst_addr, dst_port), which reads as "the relationship is the service this
process talks to". That is true only while `dst_port` names a service. Measured on this fleet:

    73 235 rows        of which 70 841 (96.7%) have a dst_port in the ephemeral range
    84 MB              and it only ever grows: 28 203 rows three days earlier
    pveproxy worker -> 127.0.0.1  =  42 348 rows over 14 116 distinct ports, each seen ONCE

Those ports are the *peer's* random client ports on a loopback connection. Nothing about them is identity:
the same pair of processes talking a second time invents a new permanent row. The fact an operator wants —
"pveproxy talks to 127.0.0.1" — is one line, which is exactly why `GET /relationships` already groups them
away at read time. Grouping at read time is a display fix over a data defect, so the rows kept accruing where
nobody looked.

THE RULE, and it takes its evidence from the data rather than from a port list: within one agent's own
reported set, a high port that is ONE OF MANY at the same address is a client port. A service does not live
on eight different random high ports of one address; a client does exactly that. Those collapse into a single
edge whose port is the sentinel 0 — a port no socket can listen on, so it cannot collide with a real one —
carrying the summed event count, the earliest first-seen and the latest last-seen.

Deliberately NOT the rule "port >= 32768 is ephemeral": mysqlx (33060), and several gRPC and cluster ports,
are real services above the floor. Measured against this corpus the quorum keeps every one of them — the 11
groups that collapse hold 42 310 of the 42 609 ephemeral ports, and the 134 groups below quorum (299 rows)
stay addressable exactly as they are.

The sentinel is a NAMED state, not a hole: `port_kind` in the API reply says `client-ports`, and
`ports_collapsed` says how many were folded in, so the count is never lost.
"""

from __future__ import annotations

from collections import defaultdict
from datetime import datetime, timezone

#: Below this, a port is service-space and is never touched. The Linux default
#: ip_local_port_range starts at 32768; nothing under it is handed out to a connecting socket.
EPHEMERAL_FLOOR = 32768

#: How many distinct high ports at one address it takes to prove they are client ports. Eight is far above
#: what any multi-port service uses at a single address, and far below the thousands a client churns through.
CLIENT_PORT_QUORUM = 8

#: The collapsed edge's port. 0 is not a listenable port, so it can never be confused with a measured one.
CLIENT_PORT_SENTINEL = 0


def _instant(stamp: object) -> datetime:
    """An unparsable stamp sorts last rather than raising: the poller must not lose a whole host's edges to
    one malformed timestamp, and the upsert downstream reports the real error on its own."""
    try:
        got = datetime.fromisoformat(str(stamp).replace("Z", "+00:00"))
    except ValueError:
        return datetime.max.replace(tzinfo=timezone.utc)
    return got if got.tzinfo else got.replace(tzinfo=timezone.utc)


def high_ports_by_key(edges: list[dict]) -> dict[tuple[str, str], list[dict]]:
    """The edges above the ephemeral floor, grouped by (comm, addr) — the candidates for a fold."""
    high: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for e in edges:
        if int(e.get("dst_port") or 0) >= EPHEMERAL_FLOOR:
            high[(e.get("comm") or "", e.get("dst_addr") or "")].append(e)
    return high


def fold(comm: str, addr: str, group: list[dict]) -> dict:
    """One edge standing for a group of client ports. Nothing about the traffic is lost — only the ports."""
    # The busiest member's latency is the one worth keeping: a single-connection edge's latency is one
    # sample, and averaging samples of unequal weight would state a number nothing measured.
    busiest = max(group, key=lambda e: int(e.get("event_count") or 0))
    return {
        **busiest,
        "comm": comm,
        "dst_addr": addr,
        "dst_port": CLIENT_PORT_SENTINEL,
        # The agent re-reports its whole remembered set every poll, so summing the members is that set's
        # total — the same "what the source currently reports" semantics the upsert's overwrite relies on.
        "event_count": sum(int(e.get("event_count") or 0) for e in group),
        # Compared as timestamps, not as text: two agents can spell the same instant "+00:00" and "Z",
        # and string order would then pick the wrong edge of the window.
        "first_seen": min((e["first_seen"] for e in group), key=_instant),
        "last_seen": max((e["last_seen"] for e in group), key=_instant),
        "ports_collapsed": len({int(e["dst_port"]) for e in group}),
    }


def collapse_client_ports(edges: list[dict], recorded_ports: dict[tuple[str, str], int] | None = None
                          ) -> list[dict]:
    """One agent's reported edges, with proven client ports folded into one edge per (comm, addr).

    Pure and total: an edge list with no such group comes back unchanged (same dicts, same order), so a host
    that talks only to services is unaffected. Input keys are the agent's dump shape — comm, dst_addr,
    dst_port, event_count, first_seen, last_seen, latency_ns.

    `recorded_ports` IS THE OTHER HALF OF THE EVIDENCE, and leaving it out was measured to be a hole rather
    than a simplification. The agent prunes its own edges at 24h, so a slow churner reports only two or three
    client ports per dump — under quorum, written individually, and the table accrues them one poll at a
    time: kube-apiserver reached 36 rows that way AFTER the batch-only rule shipped, which is the original
    pathology at a slower rate. So the quorum is asked of what has EVER been seen for that (comm, addr):
    {key: distinct high ports already in the table}, which the caller reads from `host_edges` itself.
    """
    high = high_ports_by_key(edges)
    seen = recorded_ports or {}

    collapsing = {
        key: group for key, group in high.items()
        if len({int(e["dst_port"]) for e in group}) + seen.get(key, 0) >= CLIENT_PORT_QUORUM
    }
    if not collapsing:
        return edges

    folded: set[int] = {id(e) for group in collapsing.values() for e in group}
    out = [e for e in edges if id(e) not in folded]
    out.extend(fold(comm, addr, group) for (comm, addr), group in sorted(collapsing.items()))
    return out
