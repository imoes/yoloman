"""The GELF sender (plan B9): it must put bytes on the wire exactly as the GELF spec frames them — a NUL after each
TCP message, and spec chunks for a UDP datagram too large to send whole — so these tests catch a real listening
socket, no Graylog needed. They prove the transport, not what a diagnosis says (that is test_diagnosis_export)."""

import json
import socket
import struct
import threading

import pytest

from bossman.services import gelf_send


def _free_udp():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", 0))
    return s, s.getsockname()[1]


def test_udp_small_message_is_one_datagram():
    srv, port = _free_udp()
    srv.settimeout(5)
    try:
        res = gelf_send.send([{"version": "1.1", "host": "h", "short_message": "hi"}], "127.0.0.1", port, "udp")
        assert res == {"sent": 1, "datagrams": 1, "transport": f"udp://127.0.0.1:{port}"}
        data, _ = srv.recvfrom(65535)
        assert json.loads(data)["short_message"] == "hi"
    finally:
        srv.close()


def test_udp_large_message_is_chunked_per_spec():
    srv, port = _free_udp()
    srv.settimeout(5)
    try:
        big = {"version": "1.1", "host": "h", "short_message": "x", "full_message": "A" * 20000}
        res = gelf_send.send([big], "127.0.0.1", port, "udp")
        assert res["sent"] == 1 and res["datagrams"] > 1
        chunks = {}
        total = None
        for _ in range(res["datagrams"]):
            data, _addr = srv.recvfrom(65535)
            assert data[:2] == b"\x1e\x0f", "every chunk starts with the GELF magic"
            seq, count = struct.unpack("BB", data[10:12])
            total = count
            chunks[seq] = data[12:]
        assert len(chunks) == total
        reassembled = b"".join(chunks[i] for i in range(total))
        assert json.loads(reassembled)["full_message"] == "A" * 20000
    finally:
        srv.close()


def test_tcp_messages_are_nul_terminated():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    port = srv.getsockname()[1]
    received = []

    def accept():
        conn, _ = srv.accept()
        buf = b""
        with conn:
            conn.settimeout(5)
            while b"\x00" in buf or len(received) < 2:
                try:
                    part = conn.recv(4096)
                except socket.timeout:
                    break
                if not part:
                    break
                buf += part
                while b"\x00" in buf:
                    frame, buf = buf.split(b"\x00", 1)
                    received.append(frame)

    t = threading.Thread(target=accept)
    t.start()
    res = gelf_send.send([{"short_message": "one"}, {"short_message": "two"}], "127.0.0.1", port, "tcp")
    t.join(5)
    srv.close()
    assert res == {"sent": 2, "transport": f"tcp://127.0.0.1:{port}"}
    assert [json.loads(f)["short_message"] for f in received] == ["one", "two"]


def test_no_host_is_a_named_error_not_a_silent_drop():
    with pytest.raises(ValueError, match="no GELF host"):
        gelf_send.send([{"short_message": "x"}], "", 12201, "udp")


def test_unknown_protocol_refused():
    with pytest.raises(ValueError, match="udp or tcp"):
        gelf_send.send([{"short_message": "x"}], "127.0.0.1", 12201, "sctp")
