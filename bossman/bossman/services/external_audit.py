"""Out-of-band (drift) audit via the host's Linux Audit daemon (auditd).

Bossman records who-did-what for changes IT makes; this module captures changes
made OUTSIDE Bossman — someone editing a managed config by hand, a package
postinst rewriting it, etc. It leans on auditd (standard + enabled on
RHEL/CentOS/Rocky/Alma/Fedora/SUSE; installable on Debian/Ubuntu) rather than
reinventing file watching:

  1. `build_rules(paths)` → an audit rules file that watches exactly the config
     files in the host's desired_state (`-w <path> -p wa -k bossman`), so only the
     files we manage are audited — no fleet-wide noise.
  2. the host runs `ausearch -k bossman -ts <since>` and hands Bossman the RAW
     output; `parse_ausearch(raw)` turns it into structured events.
  3. `ingest_events` writes them to the SAME audit_log the rest of the trail uses,
     tagged actor_kind="external", source="auditd" — so a hand-edit shows up in the
     Audit log / Event Browser next to Bossman's own changes, with WHO (login uid),
     WHICH process (exe), and WHEN.

The fragile part (parsing ausearch across distro versions) lives here on the
server on purpose, where it is unit-tested; the on-host collector is just
"run ausearch, send the text", which is robust everywhere.
"""

from __future__ import annotations

import re
from datetime import datetime, timezone
from typing import Any
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import DEFAULT_TENANT_ID, Agent, AuditLog
from bossman.services.audit import record_audit

AUDIT_KEY = "bossman"
RULES_PATH = "/etc/audit/rules.d/bossman.rules"


def build_rules(paths: list[str]) -> str:
    """An audit.rules file watching each managed config for writes+attribute
    changes under our key. Deduplicated + sorted so re-running is a no-op diff."""
    uniq = sorted({p.strip() for p in paths if p and p.strip()})
    lines = [
        "# Managed by Bossman — watches the files in this host's desired_state for",
        "# out-of-band changes. Regenerated on each scan; do not edit by hand.",
    ]
    lines += [f"-w {p} -p wa -k {AUDIT_KEY}" for p in uniq]
    return "\n".join(lines) + "\n"


# One audit event = all records sharing the audit(<epoch>:<serial>) id. We pull
# the epoch (event time), the PATH record's name (the file), and the SYSCALL
# record's auid (login uid = who), uid (effective), and exe (the process).
_EVENT_ID = re.compile(r"audit\((?P<epoch>\d+(?:\.\d+)?):(?P<serial>\d+)\)")
_NAME = re.compile(r'\bname="(?P<name>[^"]+)"')
_AUID = re.compile(r"\bauid=(?P<auid>\S+)")
_UID = re.compile(r"\buid=(?P<uid>\S+)")
_EXE = re.compile(r'\bexe="(?P<exe>[^"]+)"')
_COMM = re.compile(r'\bcomm="(?P<comm>[^"]+)"')
_TYPE = re.compile(r"\btype=(?P<type>\S+)")


def parse_ausearch(raw: str) -> list[dict[str, Any]]:
    """Parse raw `ausearch` output into events: one per (event-id, watched file).

    Groups records by their audit event id, then emits one event per distinct
    PATH name touched in that event — that is the file that changed. Records with
    no PATH (pure SYSCALL noise) are dropped. Robust to the block/`----` and the
    interleaved-record forms ausearch prints across versions.
    """
    # Accumulate per event id: epoch + syscall fields + the set of file names.
    events: dict[str, dict[str, Any]] = {}
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("time->") or line.startswith("----"):
            continue
        m = _EVENT_ID.search(line)
        if not m:
            continue
        eid = m.group("serial")
        ev = events.setdefault(eid, {"epoch": float(m.group("epoch")), "names": set(),
                                     "auid": None, "uid": None, "exe": None, "comm": None})
        rtype = (_TYPE.search(line) or {}).groupdict().get("type") if _TYPE.search(line) else None
        nm = _NAME.search(line)
        if nm and (rtype in (None, "PATH")):
            events[eid]["names"].add(nm.group("name"))
        if rtype in (None, "SYSCALL"):
            for rx, key in ((_AUID, "auid"), (_UID, "uid"), (_EXE, "exe"), (_COMM, "comm")):
                mm = rx.search(line)
                if mm and ev.get(key) in (None, ""):
                    ev[key] = mm.group(1)

    out: list[dict[str, Any]] = []
    for eid, ev in events.items():
        at = datetime.fromtimestamp(ev["epoch"], tz=timezone.utc).isoformat()
        # auid "unset"/4294967295 means no login uid (a daemon) — normalise to None.
        auid = ev.get("auid")
        if auid in ("unset", "4294967295", "-1"):
            auid = None
        for name in sorted(ev["names"]) or [None]:
            if name is None:
                continue
            out.append({
                "path": name, "at": at, "serial": eid,
                "auid": auid, "uid": ev.get("uid"), "exe": ev.get("exe"), "comm": ev.get("comm"),
            })
    out.sort(key=lambda e: (e["at"], e["path"]))
    return out


async def _seen(session: AsyncSession, agent: Agent, ev: dict[str, Any]) -> bool:
    """Dedup: an event is identified by (host, serial, path). ausearch overlaps
    windows, so the same change must not be logged twice."""
    target = f"{agent.name}:{ev['path']}"
    existing = await session.scalar(
        select(AuditLog.id).where(
            AuditLog.action == "fs.external_change",
            AuditLog.target == target,
            AuditLog.detail["serial"].astext == str(ev["serial"]),
        ).limit(1)
    )
    return existing is not None


async def ingest_events(session: AsyncSession, agent: Agent, events: list[dict[str, Any]]) -> int:
    """Write out-of-band change events to the shared audit_log (dedup by
    host+serial+path). Returns the number newly recorded."""
    recorded = 0
    for ev in events:
        if not ev.get("path"):
            continue
        if await _seen(session, agent, ev):
            continue
        actor = ev.get("auid") or ev.get("uid") or "unknown"
        await record_audit(
            session,
            actor=str(actor),
            actor_kind="external",
            action="fs.external_change",
            category="config",
            target=f"{agent.name}:{ev['path']}",
            detail={
                "source": "auditd", "path": ev["path"], "host": agent.name,
                "exe": ev.get("exe"), "comm": ev.get("comm"),
                "auid": ev.get("auid"), "uid": ev.get("uid"),
                "serial": ev.get("serial"), "observed_at": ev.get("at"),
            },
            tenant_id=DEFAULT_TENANT_ID,
            commit=False,
        )
        recorded += 1
    if recorded:
        await session.commit()
    return recorded


async def ingest_raw(session: AsyncSession, agent: Agent, raw: str) -> dict[str, Any]:
    """Parse raw ausearch output and ingest it. The endpoint/poller path."""
    events = parse_ausearch(raw or "")
    n = await ingest_events(session, agent, events)
    return {"parsed": len(events), "recorded": n}


def _tool_output(result: dict[str, Any]) -> tuple[int, str]:
    """(rc, stdout+stderr) from a `command` tool result (see agent_client)."""
    data = (result or {}).get("data") if isinstance(result, dict) else {}
    if not isinstance(data, dict):
        return 0, ""
    return int(data.get("rc", 0) or 0), (data.get("stdout", "") or "") + (data.get("stderr", "") or "")


async def scan_host(session: AsyncSession, agent: Agent, client: Any, paths: list[str],
                    since: str = "today") -> dict[str, Any]:
    """Live scan: (re)install the watch rules for `paths`, then read auditd for
    out-of-band changes since `since` and ingest them. Needs auditd on the host —
    returns {available: false} (no error) when it isn't, so the poller can call
    this on every host and simply skip the ones without auditd.

    `since` is passed to `ausearch -ts` (e.g. "today", "recent", "01/02/2026 …");
    dedup by (host, serial, path) makes overlapping windows safe.
    """
    import shlex

    # 1) ensure auditd + our watch rules (idempotent). rc=3 => auditctl absent.
    rules = build_rules(paths)
    setup_cmd = (
        "command -v auditctl >/dev/null 2>&1 || exit 3; "
        f"printf '%s' {shlex.quote(rules)} > {shlex.quote(RULES_PATH)}; "
        f"augenrules --load >/dev/null 2>&1 || auditctl -R {shlex.quote(RULES_PATH)} >/dev/null 2>&1 || true; "
        "echo OK"
    )
    try:
        rc, _ = _tool_output(await client.call_tool("command", {"argv": ["sh", "-lc", setup_cmd]}))
    except Exception as exc:  # noqa: BLE001 — a host we can't reach is not an error here
        return {"available": False, "reason": f"setup failed: {exc}", "parsed": 0, "recorded": 0}
    if rc == 3:
        return {"available": False, "reason": "auditd/auditctl not installed", "parsed": 0, "recorded": 0}

    # 2) read the audit trail for our key and ingest the raw text server-side.
    search_cmd = f"ausearch -k {shlex.quote(AUDIT_KEY)} -ts {shlex.quote(since)} 2>/dev/null || true"
    try:
        _rc, raw = _tool_output(await client.call_tool("command", {"argv": ["sh", "-lc", search_cmd]}))
    except Exception as exc:  # noqa: BLE001
        return {"available": True, "reason": f"ausearch failed: {exc}", "parsed": 0, "recorded": 0}
    res = await ingest_raw(session, agent, raw)
    return {"available": True, **res, "watched": len([p for p in paths if p])}
