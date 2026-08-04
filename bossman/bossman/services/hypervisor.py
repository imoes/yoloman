"""Create provisioning VMs on a hypervisor — Proxmox now, vCenter later.

The operator gives a host + credentials once; `detect()` figures out which hypervisor it is (no manual
pick), and the rest of the module lists what a VM needs placed (node, storage, network) and creates it set
up to PXE-boot into the restore flow. Credentials live vault-encrypted in the vm_hosts table; this module
only ever receives the already-decrypted username/password.

Proxmox specifics that are not obvious and each exist for a reason:
- **UEFI/OVMF** VMs need an **EFI disk** (`efidisk0`) or OVMF has nowhere to persist its boot entries and the
  PXE boot order is lost across reboots.
- A **virtio-rng** device (`rng0=/dev/urandom`) is added so the guest has entropy early — without it OVMF
  and the just-restored system can stall waiting for the entropy pool to fill (the operator called this out).
- The NIC gets `bootorder`/`boot: order=net0` so the VM PXE-boots on first start, and an optional VLAN tag.

Everything here is async httpx; TLS verification follows the vm_hosts row (self-signed labs default off).
"""

from __future__ import annotations

from typing import Any

import httpx


class HypervisorError(Exception):
    """A hypervisor API call failed, or the environment could not be detected."""


# ---------------------------------------------------------------------------
# Proxmox VE


class ProxmoxClient:
    """A thin async Proxmox VE client (ticket auth). GET needs only the ticket cookie; mutating calls also
    need the CSRF token, so both are captured at login."""

    def __init__(self, host: str, username: str, password: str, *, verify_tls: bool = False,
                 timeout: float = 30.0) -> None:
        self.base = f"https://{host}:8006/api2/json"
        self._user = username
        self._password = password
        self._verify = verify_tls
        self._timeout = timeout
        self._cookie: str | None = None
        self._csrf: str | None = None

    async def _login(self, client: httpx.AsyncClient) -> None:
        if self._cookie is not None:
            return
        try:
            r = await client.post(f"{self.base}/access/ticket",
                                  data={"username": self._user, "password": self._password})
            r.raise_for_status()
            data = r.json()["data"]
        except (httpx.HTTPError, KeyError, ValueError) as exc:
            raise HypervisorError(f"Proxmox auth failed for {self.base}: {exc}") from exc
        self._cookie = f"PVEAuthCookie={data['ticket']}"
        self._csrf = data.get("CSRFPreventionToken")

    async def _get(self, client: httpx.AsyncClient, path: str) -> Any:
        await self._login(client)
        r = await client.get(f"{self.base}{path}", headers={"Cookie": self._cookie})
        r.raise_for_status()
        return r.json().get("data")

    async def version(self) -> dict:
        """The `/version` payload — the cheapest authenticated call, used by detect()."""
        async with httpx.AsyncClient(verify=self._verify, timeout=self._timeout) as client:
            data = await self._get(client, "/version")
            return data or {}

    async def placement(self) -> dict[str, Any]:
        """Everything the wizard must let the operator pick: per node, the storages that can hold a VM disk
        and the bridges a NIC can attach to."""
        async with httpx.AsyncClient(verify=self._verify, timeout=self._timeout) as client:
            nodes_raw = await self._get(client, "/nodes") or []
            nodes = []
            for n in nodes_raw:
                node = n.get("node")
                if not node:
                    continue
                storages = await self._get(client, f"/nodes/{node}/storage") or []
                networks = await self._get(client, f"/nodes/{node}/network") or []
                nodes.append({
                    "node": node,
                    "status": n.get("status"),
                    # Storages that can hold a VM disk: content includes 'images'.
                    "storages": [
                        {"name": s.get("storage"), "type": s.get("type"),
                         "avail_bytes": s.get("avail"), "total_bytes": s.get("total")}
                        for s in storages
                        if "images" in str(s.get("content", "")) and s.get("storage")
                    ],
                    # Bridges a VM NIC attaches to (type 'bridge').
                    "bridges": [
                        {"name": b.get("iface"), "comment": b.get("comments", "").strip()}
                        for b in networks
                        if b.get("type") == "bridge" and b.get("iface")
                    ],
                })
            return {"kind": "proxmox", "nodes": nodes}


# ---------------------------------------------------------------------------
# Detection


async def detect(host: str, username: str, password: str, *, verify_tls: bool = False) -> str:
    """Which hypervisor answers at `host` for these credentials — 'proxmox' | 'vcenter'.

    Probe Proxmox first (a single authenticated /version on :8006). vCenter detection lands with the vCenter
    client in a later block; for now a Proxmox failure raises so the operator sees *why* rather than a silent
    'unknown'."""
    prox = ProxmoxClient(host, username, password, verify_tls=verify_tls, timeout=15.0)
    try:
        await prox.version()
        return "proxmox"
    except HypervisorError as exc:
        # TODO(vcenter block): try the vCenter /api/session probe here before giving up.
        raise HypervisorError(
            f"could not detect a supported hypervisor at {host!r} (Proxmox probe failed: {exc}). "
            "vCenter detection is not wired up yet.") from exc
