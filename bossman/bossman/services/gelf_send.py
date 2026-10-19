"""Send the GELF messages a diagnosis produces to a Graylog (plan B9).

`diagnosis_export.gelf()` builds one GELF 1.1 message per finding and per evidence; this module is the part that
actually puts them on the wire, over UDP or TCP, exactly to the GELF spec:

- **UDP**: each message is a JSON datagram. A message larger than `CHUNK_THRESHOLD` is split into GELF chunks
  (magic 0x1e 0x0f, an 8-byte message id, a sequence number and count, then the slice) — a datagram cannot grow
  without bound, so a long finding must be chunked or Graylog never sees it. No gzip: the messages are small and an
  uncompressed datagram is the simplest thing that is correct.
- **TCP**: the JSON messages are concatenated, each terminated by a NUL byte (`\0`) — GELF-over-TCP frames that way,
  and TCP needs no chunking.

Nothing here decides WHAT to send or interprets it; it is transport only. Sending is off unless a host is configured
(services/config.py `gelf_host`), so a diagnosis export is always available for inspection even with no Graylog.
"""

from __future__ import annotations

import json
import os
import socket
import struct

CHUNK_THRESHOLD = 8192   # a GELF message above this must be chunked over UDP
_CHUNK_PAYLOAD = 8192 - 12   # 12 bytes go to the chunk header
_MAGIC = b"\x1e\x0f"


def _udp_chunks(payload: bytes) -> list[bytes]:
    """Split one oversized GELF message into spec chunks; a message that fits is sent whole by the caller."""
    message_id = os.urandom(8)
    parts = [payload[i:i + _CHUNK_PAYLOAD] for i in range(0, len(payload), _CHUNK_PAYLOAD)]
    if len(parts) > 128:
        raise ValueError(f"GELF message needs {len(parts)} chunks; the spec allows at most 128")
    count = len(parts)
    return [_MAGIC + message_id + struct.pack("BB", seq, count) + part for seq, part in enumerate(parts)]


def send(messages: list[dict], host: str, port: int, protocol: str = "udp", timeout: float = 5.0) -> dict:
    """Send every GELF message to host:port. Returns what was sent and the transport used; raises on a connection
    or encoding error so the caller can report the reason, never a silent drop."""
    if not host:
        raise ValueError("no GELF host configured (BOSSMAN_GELF_HOST is empty)")
    if protocol not in ("udp", "tcp"):
        raise ValueError("gelf protocol must be udp or tcp")
    encoded = [json.dumps(m, ensure_ascii=False).encode("utf-8") for m in messages]

    if protocol == "tcp":
        with socket.create_connection((host, port), timeout=timeout) as sock:
            for payload in encoded:
                sock.sendall(payload + b"\x00")   # GELF-over-TCP: NUL-terminated frames
        return {"sent": len(encoded), "transport": f"tcp://{host}:{port}"}

    datagrams = 0
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(timeout)
        for payload in encoded:
            if len(payload) <= CHUNK_THRESHOLD:
                sock.sendto(payload, (host, port))
                datagrams += 1
            else:
                for chunk in _udp_chunks(payload):
                    sock.sendto(chunk, (host, port))
                    datagrams += 1
    return {"sent": len(encoded), "datagrams": datagrams, "transport": f"udp://{host}:{port}"}
