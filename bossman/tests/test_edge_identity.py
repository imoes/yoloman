"""A client port is not a relationship — the rule that stops host_edges growing per connection.

Measured before the rule: 73 235 rows / 84 MB on this fleet, 96.7% of them a single connection to a peer's
random high port, and `pveproxy worker -> 127.0.0.1` alone holding 42 348 of them over 14 116 ports. The
API already grouped them away at read time, which is why the table could grow unnoticed.
"""

from bossman.services.edge_identity import (
    CLIENT_PORT_QUORUM,
    CLIENT_PORT_SENTINEL,
    EPHEMERAL_FLOOR,
    collapse_client_ports,
)


def edge(port: int, *, comm: str = "kubelet", addr: str = "127.0.0.1", count: int = 1,
         first: str = "2026-08-26T10:00:00+00:00", last: str = "2026-08-26T10:00:00+00:00") -> dict:
    return {"comm": comm, "dst_addr": addr, "dst_port": port, "event_count": count,
            "first_seen": first, "last_seen": last, "latency_ns": 1_000_000}


def test_many_high_ports_at_one_address_become_one_edge():
    got = collapse_client_ports([edge(40000 + i) for i in range(CLIENT_PORT_QUORUM)])
    assert len(got) == 1
    assert got[0]["dst_port"] == CLIENT_PORT_SENTINEL
    assert got[0]["ports_collapsed"] == CLIENT_PORT_QUORUM


def test_the_connection_count_survives_the_fold():
    """What the fold keeps is the magnitude: 8 connections stay 8, not 1. The ports were the meaningless
    part; how much traffic there was is not."""
    got = collapse_client_ports([edge(40000 + i, count=3) for i in range(CLIENT_PORT_QUORUM)])
    assert got[0]["event_count"] == 3 * CLIENT_PORT_QUORUM


def test_the_window_is_the_union_of_the_members():
    edges = [edge(40000 + i) for i in range(CLIENT_PORT_QUORUM)]
    edges[0]["first_seen"] = "2026-08-01T00:00:00+00:00"
    edges[3]["last_seen"] = "2026-08-26T23:59:00+00:00"
    got = collapse_client_ports(edges)[0]
    assert got["first_seen"] == "2026-08-01T00:00:00+00:00"
    assert got["last_seen"] == "2026-08-26T23:59:00+00:00"


def test_the_window_is_compared_as_time_not_as_text():
    """`Z` and `+00:00` spell the same instant and sort differently as strings."""
    edges = [edge(40000 + i) for i in range(CLIENT_PORT_QUORUM)]
    edges[0]["first_seen"] = "2026-08-01T00:00:00Z"
    got = collapse_client_ports(edges)[0]
    assert got["first_seen"] == "2026-08-01T00:00:00Z"


def test_a_few_high_ports_are_left_alone():
    """mysqlx lives on 33060 and gRPC services on 50051 — real services above the ephemeral floor. Below the
    quorum nothing proves a port is a client's, so nothing is folded."""
    edges = [edge(33060, count=90), edge(50051, count=40)]
    assert collapse_client_ports(edges) == edges


def test_service_ports_are_never_folded_however_many():
    edges = [edge(p) for p in range(1000, 1000 + CLIENT_PORT_QUORUM * 2)]
    assert collapse_client_ports(edges) == edges
    assert all(e["dst_port"] >= 1000 for e in edges)


def test_the_floor_is_the_linux_ephemeral_range():
    below = [edge(EPHEMERAL_FLOOR - 1 - i) for i in range(CLIENT_PORT_QUORUM)]
    assert collapse_client_ports(below) == below


def test_a_service_edge_at_the_same_address_survives_the_fold():
    """kubelet talks to 127.0.0.1:6443 AND churns through client ports. Folding must not swallow the one
    statement an operator actually reads."""
    got = collapse_client_ports([edge(6443, count=500)] + [edge(40000 + i) for i in range(20)])
    ports = sorted(e["dst_port"] for e in got)
    assert ports == [CLIENT_PORT_SENTINEL, 6443]
    assert next(e for e in got if e["dst_port"] == 6443)["event_count"] == 500


def test_each_process_and_address_folds_separately():
    edges = ([edge(40000 + i, comm="kubelet") for i in range(10)]
             + [edge(40000 + i, comm="kube-apiserver") for i in range(10)]
             + [edge(40000 + i, addr="10.0.0.5") for i in range(10)])
    got = collapse_client_ports(edges)
    assert len(got) == 3
    assert {(e["comm"], e["dst_addr"]) for e in got} == {
        ("kubelet", "127.0.0.1"), ("kube-apiserver", "127.0.0.1"), ("kubelet", "10.0.0.5")}


def test_an_untouched_list_is_returned_as_is():
    """Same objects, same order: a host that only talks to services must not be reshaped at all."""
    edges = [edge(22), edge(443), edge(33060)]
    assert collapse_client_ports(edges) is edges


def test_the_busiest_members_latency_is_the_one_kept():
    edges = [edge(40000 + i) for i in range(CLIENT_PORT_QUORUM)]
    edges[5].update(event_count=99, latency_ns=7_000_000)
    assert collapse_client_ports(edges)[0]["latency_ns"] == 7_000_000


def test_an_unparsable_timestamp_does_not_lose_the_host():
    edges = [edge(40000 + i) for i in range(CLIENT_PORT_QUORUM)]
    edges[2]["last_seen"] = "not a timestamp"
    got = collapse_client_ports(edges)
    assert len(got) == 1 and got[0]["dst_port"] == CLIENT_PORT_SENTINEL


def test_the_table_s_own_history_counts_toward_the_quorum():
    """The hole a batch-only rule left, measured: the agent forgets its edges after 24h, so a slow churner
    reports two or three client ports per dump — under quorum, written individually, and the table accrues
    them one poll at a time. kube-apiserver was back to 36 rows for one (comm, addr) within the hour."""
    edges = [edge(40000), edge(40001)]
    assert collapse_client_ports(edges) == edges, "two ports alone prove nothing"
    got = collapse_client_ports(edges, {("kubelet", "127.0.0.1"): 34})
    assert len(got) == 1 and got[0]["dst_port"] == CLIENT_PORT_SENTINEL


def test_recorded_history_for_another_key_does_not_fold_this_one():
    edges = [edge(40000), edge(40001)]
    assert collapse_client_ports(edges, {("kube-apiserver", "127.0.0.1"): 99}) == edges


def test_recorded_history_alone_does_not_invent_an_edge():
    """No high port in the dump, nothing to fold — the recorded count must not conjure a sentinel."""
    edges = [edge(443)]
    assert collapse_client_ports(edges, {("kubelet", "127.0.0.1"): 500}) == edges
