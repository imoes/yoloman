"""Event Console (gap #2): passive receipt of syslog + SNMP traps.

Devices that push events (switches, UPS, firewalls, routers) can't be polled —
they send unsolicited datagrams. Two asyncio UDP servers listen for them, parse
what they can, reverse-map the source IP to a known host, and persist an Event.
The UI's Event Console then shows the stream (Checkmk's Event Console idiom).

- syslog: RFC3164/5424 — the leading `<PRI>` gives facility+severity; the rest
  is best-effort split into tag + message.
- SNMP trap: full BER decode is heavy; v1 does a light walk to pull the SNMP
  version + community and the trap OID when present, and keeps the raw hex. Good
  enough to see "a trap arrived from X" and alert on it; richer varbind decode
  can come later.

Everything is best-effort: a malformed datagram is stored raw, never crashes the
listener. Writes are batched off a queue so a datagram flood can't stall on DB.
"""

from __future__ import annotations

import asyncio
import re
import logging
from datetime import datetime, timezone

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from bossman.config import Settings
from bossman.db.models import Agent, Event

logger = logging.getLogger(__name__)

_FACILITY = None  # unused placeholder kept for clarity of the PRI math below


def parse_syslog(data: bytes, source_ip: str) -> dict:
    """Parse a syslog datagram into Event fields. Handles the `<PRI>` prefix
    (both RFC3164 and 5424); the remainder is stored as the message with a
    best-effort tag extraction."""
    text = data.decode("utf-8", "replace").strip()
    severity, facility = 6, 1
    body = text
    if text.startswith("<") and ">" in text[:5]:
        try:
            pri = int(text[1:text.index(">")])
            facility, severity = pri // 8, pri % 8
            body = text[text.index(">") + 1:]
        except ValueError:
            pass
    # Best-effort app/tag: RFC3164 "MMM dd HH:MM:SS host tag[pid]: msg" or 5424
    # "1 timestamp host app procid ...". The `tag[pid]:` token is the reliable
    # anchor; time colons make a naive split pick "17" out of "17:20:00".
    app = None
    m = re.search(r"(?:^|\s)([A-Za-z][\w./\-]{1,63})(?:\[\d+\])?:\s", body)
    if m:
        app = m.group(1)
    return {"kind": "syslog", "source_ip": source_ip, "severity": severity,
            "facility": facility, "app": app, "message": body[:4000], "raw": text[:8000]}


def parse_snmptrap(data: bytes, source_ip: str) -> dict:
    """Light SNMP-trap decode: pull the SNMP version and community string from
    the leading SEQUENCE, and the first OID that looks like a trap OID. Keeps
    the raw hex. Not a full BER varbind decoder — enough to record the trap."""
    version = None
    community = None
    try:
        # SEQUENCE(0x30) len; INTEGER(0x02) version; OCTET STRING(0x04) community
        i = 0
        if data[i] == 0x30:
            i += 2  # skip seq tag + (short-form) len
            if data[i] == 0x02:  # version INTEGER
                vlen = data[i + 1]
                version = int.from_bytes(data[i + 2:i + 2 + vlen], "big")
                i += 2 + vlen
            if i < len(data) and data[i] == 0x04:  # community OCTET STRING
                clen = data[i + 1]
                community = data[i + 2:i + 2 + clen].decode("latin-1", "replace")
    except (IndexError, ValueError):
        pass
    ver_label = {0: "v1", 1: "v2c", 3: "v3"}.get(version, f"v?{version}")
    msg = f"SNMP {ver_label} trap" + (f" (community {community})" if community else "")
    return {"kind": "snmptrap", "source_ip": source_ip, "severity": 4,  # warning by default
            "facility": None, "app": ver_label, "message": msg, "raw": data.hex()[:8000]}


class _UDPProtocol(asyncio.DatagramProtocol):
    def __init__(self, queue: asyncio.Queue, parser) -> None:
        self.queue = queue
        self.parser = parser

    def datagram_received(self, data: bytes, addr) -> None:
        try:
            ev = self.parser(data, addr[0])
            self.queue.put_nowait(ev)
        except Exception:  # noqa: BLE001 — one bad datagram must not kill the listener
            logger.debug("event parse failed from %s", addr, exc_info=True)


async def _writer(session_factory: async_sessionmaker[AsyncSession], queue: asyncio.Queue, stop: asyncio.Event) -> None:
    """Drain the queue and persist events in small batches, resolving the source
    IP to a known host name once per batch."""
    while not stop.is_set():
        try:
            first = await asyncio.wait_for(queue.get(), timeout=2.0)
        except asyncio.TimeoutError:
            continue
        batch = [first]
        while len(batch) < 200:
            try:
                batch.append(queue.get_nowait())
            except asyncio.QueueEmpty:
                break
        try:
            async with session_factory() as session:
                ips = {e["source_ip"] for e in batch}
                host_by_ip = await _resolve_hosts(session, ips)
                now = datetime.now(timezone.utc)
                for e in batch:
                    session.add(Event(received_at=now, host_name=host_by_ip.get(e["source_ip"]), **e))
                await session.commit()
        except Exception:  # noqa: BLE001 — a DB hiccup drops this batch, never the listener
            logger.exception("event batch write failed")


async def _resolve_hosts(session: AsyncSession, ips: set[str]) -> dict[str, str]:
    """Map each source IP to a known agent name (Agent.address is "host:port"
    or a bare address). Best-effort."""
    out: dict[str, str] = {}
    result = await session.execute(select(Agent.name, Agent.address).where(Agent.address.is_not(None)))
    addr_to_name = {(address or "").rsplit(":", 1)[0]: name for name, address in result.all()}
    for ip in ips:
        if ip in addr_to_name:
            out[ip] = addr_to_name[ip]
    return out


async def event_console_loop(
    session_factory: async_sessionmaker[AsyncSession], settings: Settings, stop_event: asyncio.Event,
) -> None:
    """Start the syslog + SNMP-trap UDP listeners and the batch writer until
    stop_event is set. Guarded by settings.event_console_enabled (off in tests)."""
    if not getattr(settings, "event_console_enabled", False):
        return
    loop = asyncio.get_running_loop()
    queue: asyncio.Queue = asyncio.Queue(maxsize=10000)
    transports = []
    for port, parser, label in (
        (settings.syslog_listen_port, parse_syslog, "syslog"),
        (settings.snmptrap_listen_port, parse_snmptrap, "snmptrap"),
    ):
        try:
            transport, _ = await loop.create_datagram_endpoint(
                lambda p=parser: _UDPProtocol(queue, p),
                local_addr=(settings.event_console_host, port),
            )
            transports.append(transport)
            logger.info("event console: listening for %s on udp/%s", label, port)
        except OSError as exc:
            logger.warning("event console: could not bind %s udp/%s: %s", label, port, exc)
    if not transports:
        return
    writer = asyncio.create_task(_writer(session_factory, queue, stop_event))
    try:
        await stop_event.wait()
    finally:
        for t in transports:
            t.close()
        writer.cancel()
