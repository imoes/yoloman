"""Which DHCP the PXE container may serve right now — derived from the active restore jobs, the one source.

Three named states:

* ``restricted`` — every active job names its MAC. dnsmasq answers exactly those MACs
  (``dhcp-host=<mac>`` + ``dhcp-ignore=tag:!known``); every other machine on the segment is ignored. This is
  what deploy_vm produces: the hypervisor hands out the new VM's MAC and the job is keyed on it.
* ``open`` — a wildcard job (armed without a MAC, the "next machine that boots claims it" case) is active
  and still inside its window (``netboot_open_dhcp_minutes`` after it was armed). dnsmasq answers anyone, but
  only for that window; once a machine claims the job its MAC is recorded and the state becomes
  ``restricted`` on its own.
* ``off`` — nothing to serve, or netboot is disabled, or the only wildcard job's window has ended.

Every answer carries ``dhcp_reason``, so the container log and the UI say why DHCP is what it is.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any

from sqlalchemy import select

from bossman.db.models import NetinstallJob, RestoreJob


def static_address(job) -> str | None:
    """The bare IP of a job's static network ({"address": "192.0.2.137/24"}), or None."""
    addr = str((getattr(job, "network", None) or {}).get("address") or "").split("/")[0]
    return addr or None


async def policy(session, *, enabled: bool, open_minutes: int, now: datetime | None = None) -> dict[str, Any]:
    now = now or datetime.now(timezone.utc)
    if not enabled:
        return {"dhcp": False, "dhcp_mode": "off", "dhcp_macs": [], "dhcp_hosts": [], "dhcp_open_until": None,
                "dhcp_reason": "netboot is disabled"}
    jobs = (await session.scalars(select(RestoreJob).where(RestoreJob.status.in_(("pending", "running"))))).all()
    installs = (await session.scalars(select(NetinstallJob).where(NetinstallJob.status.in_(("pending", "installing"))))).all()
    # A netinstall job always has its MAC (it comes from the hypervisor), so it only ever restricts.
    macs = sorted({j.target_mac for j in jobs if j.target_mac} | {j.target_mac for j in installs})
    # Each MAC gets the static address its deployment was checked for, so the PXE DHCP pool can never run dry:
    # three parallel installs exhausted a two-address range (the third MAC got "no address available").
    # A restore job has no address yet (the PE image sets it in a later step), so it keeps using the range.
    hosts = {j.target_mac: a for j in installs if (a := static_address(j))}
    dhcp_hosts = [{"mac": m, "address": hosts.get(m)} for m in macs]
    wildcards = [j for j in jobs if not j.target_mac]
    window = timedelta(minutes=open_minutes)
    open_until = None
    expired_since = None
    for j in wildcards:
        armed = j.created_at if j.created_at.tzinfo else j.created_at.replace(tzinfo=timezone.utc)
        until = armed + window
        if until > now:
            open_until = max(open_until or until, until)
        else:
            expired_since = max(expired_since or until, until)
    if open_until is not None:
        return {"dhcp": True, "dhcp_mode": "open", "dhcp_macs": macs, "dhcp_hosts": dhcp_hosts, "dhcp_open_until": open_until.isoformat(),
                "dhcp_reason": f"a restore job without a MAC is armed; DHCP answers every machine until "
                               f"{open_until.isoformat()} ({open_minutes} min window)"}
    if macs:
        reason = f"{len(macs)} job(s) keyed on a MAC; DHCP answers only {', '.join(macs)}"
        if expired_since is not None:
            reason += f" (a job without a MAC is armed too, but its open window ended {expired_since.isoformat()})"
        return {"dhcp": True, "dhcp_mode": "restricted", "dhcp_macs": macs, "dhcp_hosts": dhcp_hosts, "dhcp_open_until": None, "dhcp_reason": reason}
    if expired_since is not None:
        return {"dhcp": False, "dhcp_mode": "off", "dhcp_macs": [], "dhcp_hosts": [], "dhcp_open_until": None,
                "dhcp_reason": f"the only active job has no MAC and its open window ended {expired_since.isoformat()}; "
                               "give it the target's MAC or re-arm it"}
    return {"dhcp": False, "dhcp_mode": "off", "dhcp_macs": [], "dhcp_hosts": [], "dhcp_open_until": None,
            "dhcp_reason": "no active restore job"}
