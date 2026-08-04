"""Create provisioning VMs on a hypervisor — Proxmox and vCenter.

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

import base64
import random
from typing import Any

import httpx


class HypervisorError(Exception):
    """A hypervisor API call failed, or the environment could not be detected."""


def gen_mac() -> str:
    """A locally-administered QEMU-style MAC (52:54:00:xx:xx:xx). We assign the NIC's MAC ourselves so the
    restore job can be armed against it before the VM has ever booted — the PXE check-in identifies the
    machine by MAC alone."""
    return "52:54:00:%02x:%02x:%02x" % (random.randint(0, 255), random.randint(0, 255), random.randint(0, 255))


def _proxmox_vm_config(
    *, name: str, cores: int, memory_mb: int, disk_gib: int, storage: str, bridge: str,
    mac: str, vlan: int | None, uefi: bool,
) -> dict[str, Any]:
    """Assemble the POST /nodes/{node}/qemu body for a PXE-install target. Pure (no I/O) so it is unit-
    tested directly — the subtle parts (UEFI needs efidisk0, entropy needs rng0, PXE needs net-first boot)
    all live here.

    - `net0`: virtio NIC with OUR mac, on `bridge`, optionally VLAN-tagged. `boot: order=net0` makes the VM
      PXE-boot on first start, which is the whole point.
    - `scsi0`: a blank disk of the target size on `storage` — this is what the template restores onto.
    - UEFI (`bios: ovmf`) additionally needs `efidisk0`, or OVMF has nowhere to persist boot entries and the
      net-first order is lost across the post-install reboot.
    - `rng0` (virtio-rng from /dev/urandom): the guest gets entropy early, so OVMF and the freshly restored
      system do not stall waiting for the entropy pool.
    """
    net = f"virtio={mac},bridge={bridge}"
    if vlan:
        net += f",tag={vlan}"
    cfg: dict[str, Any] = {
        "name": name,
        "cores": cores,
        "memory": memory_mb,
        "ostype": "l26",
        "scsihw": "virtio-scsi-single",
        "scsi0": f"{storage}:{disk_gib}",
        "net0": net,
        "boot": "order=net0",
        "rng0": "source=/dev/urandom",
        "agent": "1",
    }
    if uefi:
        cfg["bios"] = "ovmf"
        cfg["efidisk0"] = f"{storage}:1,efitype=4m,pre-enrolled-keys=0"
    return cfg


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

    async def _post(self, client: httpx.AsyncClient, path: str, data: dict) -> Any:
        await self._login(client)
        headers = {"Cookie": self._cookie}
        if self._csrf:
            headers["CSRFPreventionToken"] = self._csrf   # required for every mutating call
        r = await client.post(f"{self.base}{path}", headers=headers, data=data)
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

    async def create_vm(
        self, node: str, name: str, *, cores: int, memory_mb: int, disk_gib: int, storage: str,
        bridge: str, uefi: bool, vlan: int | None = None, mac: str | None = None,
    ) -> dict[str, Any]:
        """Create a PXE-install VM on `node` and start it. Returns {vmid, mac}. The MAC is ours (assigned,
        not read back) so the restore job can be armed against it immediately; starting the VM makes it
        PXE-boot into the restore flow."""
        mac = mac or gen_mac()
        async with httpx.AsyncClient(verify=self._verify, timeout=self._timeout) as client:
            try:
                vmid = int(await self._get(client, "/cluster/nextid"))
                cfg = _proxmox_vm_config(name=name, cores=cores, memory_mb=memory_mb, disk_gib=disk_gib,
                                         storage=storage, bridge=bridge, mac=mac, vlan=vlan, uefi=uefi)
                cfg["vmid"] = vmid
                await self._post(client, f"/nodes/{node}/qemu", cfg)
                await self._post(client, f"/nodes/{node}/qemu/{vmid}/status/start", {})
            except (httpx.HTTPError, KeyError, ValueError) as exc:
                raise HypervisorError(f"Proxmox VM create on {node} failed: {exc}") from exc
        return {"vmid": vmid, "mac": mac}


# ---------------------------------------------------------------------------
# VMware vCenter


def _vcenter_vm_spec(
    *, name: str, guest_os: str, cores: int, memory_mb: int, disk_bytes: int,
    host_id: str, datastore_id: str, folder_id: str, resource_pool_id: str,
    network_id: str, network_type: str, mac: str, uefi: bool,
) -> dict[str, Any]:
    """The POST /api/vcenter/vm body for a PXE-install VM. Pure, so it is unit-tested directly.

    - `boot.type` EFI vs BIOS mirrors the image's firmware.
    - `boot_devices=[ETHERNET]` makes the VM PXE-boot first, the vCenter analogue of Proxmox's net-first
      boot order.
    - the NIC uses a MANUAL mac (ours) so the restore job can be armed against it, on the chosen portgroup;
      `backing.type` follows whether the network is a standard or distributed portgroup.
    - VLAN is NOT set here: on vCenter the portgroup carries the VLAN, unlike Proxmox's per-NIC tag.
    """
    return {
        "name": name,
        "guest_OS": guest_os,
        "placement": {
            "host": host_id, "datastore": datastore_id,
            "folder": folder_id, "resource_pool": resource_pool_id,
        },
        "cpu": {"count": cores},
        "memory": {"size_MiB": memory_mb},
        "disks": [{"new_vmdk": {"capacity": disk_bytes}}],
        "nics": [{
            "mac_type": "MANUAL", "mac_address": mac,
            "backing": {"type": network_type, "network": network_id},
        }],
        "boot": {"type": "EFI" if uefi else "BIOS"},
        "boot_devices": [{"type": "ETHERNET"}],
    }


class VCenterClient:
    """A thin async vCenter REST client (session auth). Login is Basic-auth POST /api/session returning a
    session id; every other call carries it as `vmware-api-session-id`."""

    def __init__(self, host: str, username: str, password: str, *, verify_tls: bool = False,
                 timeout: float = 30.0) -> None:
        self.base = f"https://{host}/api"
        self._user = username
        self._password = password
        self._verify = verify_tls
        self._timeout = timeout
        self._session: str | None = None

    async def _login(self, client: httpx.AsyncClient) -> None:
        if self._session is not None:
            return
        cred = base64.b64encode(f"{self._user}:{self._password}".encode()).decode()
        try:
            r = await client.post(f"{self.base}/session", headers={"Authorization": f"Basic {cred}"})
            r.raise_for_status()
            self._session = r.json() if isinstance(r.json(), str) else r.json().get("value")
        except (httpx.HTTPError, ValueError) as exc:
            raise HypervisorError(f"vCenter auth failed for {self.base}: {exc}") from exc
        if not self._session:
            raise HypervisorError(f"vCenter auth returned no session for {self.base}")

    @staticmethod
    def _unwrap(r: httpx.Response) -> Any:
        """Decode a vCenter response. A 204/empty body (e.g. a power action) is None; newer vCenter returns
        the value directly, older wraps it in {"value": …}."""
        if not r.content:
            return None
        body = r.json()
        return body.get("value") if isinstance(body, dict) and "value" in body else body

    async def _get(self, client: httpx.AsyncClient, path: str) -> Any:
        await self._login(client)
        r = await client.get(f"{self.base}{path}", headers={"vmware-api-session-id": self._session})
        r.raise_for_status()
        return self._unwrap(r)

    async def _post(self, client: httpx.AsyncClient, path: str, payload: dict) -> Any:
        await self._login(client)
        r = await client.post(f"{self.base}{path}", headers={"vmware-api-session-id": self._session},
                              json=payload)
        r.raise_for_status()
        return self._unwrap(r)

    async def probe(self) -> None:
        """Cheapest confirmation that this really is vCenter for these creds — a successful session login."""
        async with httpx.AsyncClient(verify=self._verify, timeout=self._timeout) as client:
            await self._login(client)

    async def placement(self) -> dict[str, Any]:
        """Same shape as ProxmoxClient.placement, so the wizard needs no vCenter-specific UI: each ESXi host
        is a `node`; datastores map to `storages` and networks (portgroups) to `bridges`. Datastores and
        networks are cluster-shared, so each host lists them all."""
        async with httpx.AsyncClient(verify=self._verify, timeout=self._timeout) as client:
            hosts = await self._get(client, "/vcenter/host") or []
            datastores = await self._get(client, "/vcenter/datastore") or []
            networks = await self._get(client, "/vcenter/network") or []
            storages = [{"name": d.get("name"), "id": d.get("datastore"), "type": d.get("type"),
                         "avail_bytes": d.get("free_space"), "total_bytes": d.get("capacity")}
                        for d in datastores if d.get("datastore")]
            bridges = [{"name": n.get("name"), "id": n.get("network"), "type": n.get("type")}
                       for n in networks if n.get("network")]
            nodes = [{"node": h.get("name"), "id": h.get("host"), "status": h.get("connection_state"),
                      "storages": storages, "bridges": bridges}
                     for h in hosts if h.get("host")]
            return {"kind": "vcenter", "nodes": nodes}

    async def create_vm(
        self, node: str, name: str, *, cores: int, memory_mb: int, disk_gib: int, storage: str,
        bridge: str, uefi: bool, vlan: int | None = None, mac: str | None = None,
    ) -> dict[str, Any]:
        """Create a PXE-install VM. `node`/`storage`/`bridge` are the NAMES the wizard offered; they are
        resolved to vCenter ids here, and a VM folder + resource pool are picked (first available). Returns
        {vmid, mac}. `vlan` is accepted for a uniform signature but not applied — the portgroup carries it."""
        mac = mac or gen_mac()
        async with httpx.AsyncClient(verify=self._verify, timeout=self._timeout) as client:
            try:
                hosts = await self._get(client, "/vcenter/host") or []
                datastores = await self._get(client, "/vcenter/datastore") or []
                networks = await self._get(client, "/vcenter/network") or []
                folders = await self._get(client, "/vcenter/folder?filter.type=VIRTUAL_MACHINE") or []
                pools = await self._get(client, "/vcenter/resource-pool") or []

                host_id = _by_name(hosts, node, "host")
                datastore_id = _by_name(datastores, storage, "datastore")
                net = _first(networks, lambda n: n.get("name") == bridge)
                if not (host_id and datastore_id and net and folders and pools):
                    raise HypervisorError(
                        "could not resolve vCenter placement (host/datastore/network/folder/resource-pool)")
                net_type = ("DISTRIBUTED_PORTGROUP" if net.get("type") == "DISTRIBUTED_PORTGROUP"
                            else "STANDARD_PORTGROUP")
                spec = _vcenter_vm_spec(
                    name=name, guest_os="OTHER_64", cores=cores, memory_mb=memory_mb,
                    disk_bytes=disk_gib * 1024 * 1024 * 1024, host_id=host_id, datastore_id=datastore_id,
                    folder_id=folders[0].get("folder"), resource_pool_id=pools[0].get("resource_pool"),
                    network_id=net.get("network"), network_type=net_type, mac=mac, uefi=uefi)
                vmid = await self._post(client, "/vcenter/vm", {"spec": spec})
                await self._post(client, f"/vcenter/vm/{vmid}/power?action=start", {})
            except (httpx.HTTPError, KeyError, ValueError) as exc:
                raise HypervisorError(f"vCenter VM create failed: {exc}") from exc
        return {"vmid": vmid, "mac": mac}


def _first(items: list, pred) -> Any:
    return next((x for x in items if pred(x)), None)


def _by_name(items: list, name: str, id_key: str) -> str | None:
    m = _first(items, lambda x: x.get("name") == name)
    return m.get(id_key) if m else None


# ---------------------------------------------------------------------------
# Detection


async def detect(host: str, username: str, password: str, *, verify_tls: bool = False) -> str:
    """Which hypervisor answers at `host` for these credentials — 'proxmox' | 'vcenter'.

    Probe Proxmox first (authenticated /version on :8006), then vCenter (a /api/session login). Whichever
    accepts the credentials wins; if neither does, raise with both reasons so the operator sees why."""
    prox = ProxmoxClient(host, username, password, verify_tls=verify_tls, timeout=15.0)
    try:
        await prox.version()
        return "proxmox"
    except HypervisorError as prox_exc:
        vc = VCenterClient(host, username, password, verify_tls=verify_tls, timeout=15.0)
        try:
            await vc.probe()
            return "vcenter"
        except HypervisorError as vc_exc:
            raise HypervisorError(
                f"no supported hypervisor at {host!r}: Proxmox probe failed ({prox_exc}); "
                f"vCenter probe failed ({vc_exc})") from vc_exc
