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

import asyncio
import base64
import logging
import random
import re
from typing import Any

import httpx

log = logging.getLogger(__name__)


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

    - `net0`: virtio NIC with OUR mac, on `bridge`, optionally VLAN-tagged.
    - `scsi0`: a blank disk of the target size on `storage` — this is what the template restores onto.
    - `boot: order=scsi0;net0` — DISK FIRST, network fallback. On the first boot the disk is empty (no boot
      sector) so the firmware falls through to net0 and PXE-boots into the restore. After the restore has
      written the OS, the same order boots the disk directly — no re-PXE loop. (An earlier `order=net0`
      never listed the disk, so a BIOS VM PXE-booted forever and never came up on the restored system.)
    - UEFI (`bios: ovmf`) additionally needs `efidisk0`, or OVMF has nowhere to persist boot entries.
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
        "boot": "order=scsi0;net0",
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
        """The `/version` payload — the cheapest authenticated call; detect() uses it only to VALIDATE the
        credentials once the product has already been identified by fingerprint()."""
        async with httpx.AsyncClient(verify=self._verify, timeout=self._timeout) as client:
            data = await self._get(client, "/version")
            return data or {}

    async def fingerprint(self) -> dict[str, Any] | None:
        """Identify the product WITHOUT credentials: is a Proxmox VE API answering on :8006? Returns
        {"product": "proxmox", "version": None} or None.

        This is the discriminator, not auth. `GET /api2/json/version` needs a login and so returns 401 when
        called cold — but the *response* still identifies the product: the `pve-api-daemon` Server banner (and
        the `{"data": …}` JSON envelope) are Proxmox-specific and present even on the 401. So identity comes
        from the API surface, which is why the same service account also existing on a vCenter cannot cause a
        misidentification. The version itself needs auth, so it is left None here and filled by version()."""
        try:
            async with httpx.AsyncClient(verify=self._verify, timeout=self._timeout) as client:
                r = await client.get(f"{self.base}/version")
        except httpx.HTTPError:
            return None
        server = r.headers.get("server", "").lower()
        if r.status_code in (200, 401) and ("pve" in server or _is_pve_envelope(r)):
            return {"product": "proxmox", "version": None}
        return None

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

    async def _wait_task(self, client: httpx.AsyncClient, node: str, upid: Any, *, what: str) -> None:
        """Proxmox create/start return a UPID and do the real work ASYNCHRONOUSLY — a plain HTTP 200 only
        means the task was *accepted*, not that it succeeded. So poll the task to completion and raise if it
        failed; otherwise a duplicate VM, a full datastore, etc. would be silently swallowed."""
        if not (isinstance(upid, str) and upid.startswith("UPID:")):
            return   # not a task-returning call — nothing to wait for
        for _ in range(120):   # ~120 s ceiling; VM create/start is normally a second or two
            status = await self._get(client, f"/nodes/{node}/tasks/{upid}/status") or {}
            if status.get("status") == "stopped":
                exit_status = status.get("exitstatus")
                if exit_status and exit_status != "OK":
                    raise HypervisorError(f"Proxmox task '{what}' failed: {exit_status}")
                return
            await asyncio.sleep(1.0)
        raise HypervisorError(f"Proxmox task '{what}' did not finish within 120s")

    async def create_vm(
        self, node: str, name: str, *, cores: int, memory_mb: int, disk_gib: int, storage: str,
        bridge: str, uefi: bool, vlan: int | None = None, mac: str | None = None,
    ) -> dict[str, Any]:
        """Create a PXE-install VM on `node` and start it. Returns {vmid, mac}. The MAC is ours (assigned,
        not read back) so the restore job can be armed against it immediately; starting the VM makes it
        PXE-boot into the restore flow.

        Errors are surfaced, never swallowed: a name already in use is rejected up front, and the async
        create/start tasks are waited on so a failure (e.g. a config that already exists) becomes a raised
        HypervisorError instead of a false success."""
        mac = mac or gen_mac()
        async with httpx.AsyncClient(verify=self._verify, timeout=self._timeout) as client:
            try:
                # Reject a duplicate name up front with a clear message, rather than creating a confusing
                # second VM (Proxmox keys by vmid, so it would otherwise allow the clash silently).
                existing = await self._get(client, "/cluster/resources?type=vm") or []
                clash = next((r for r in existing if r.get("name") == name), None)
                if clash is not None:
                    raise HypervisorError(
                        f"a VM named {name!r} already exists on this cluster "
                        f"(vmid {clash.get('vmid')} on node {clash.get('node')})")

                vmid = int(await self._get(client, "/cluster/nextid"))
                cfg = _proxmox_vm_config(name=name, cores=cores, memory_mb=memory_mb, disk_gib=disk_gib,
                                         storage=storage, bridge=bridge, mac=mac, vlan=vlan, uefi=uefi)
                cfg["vmid"] = vmid
                create_upid = await self._post(client, f"/nodes/{node}/qemu", cfg)
                await self._wait_task(client, node, create_upid, what=f"create VM {vmid} ({name})")
                start_upid = await self._post(client, f"/nodes/{node}/qemu/{vmid}/status/start", {})
                await self._wait_task(client, node, start_upid, what=f"start VM {vmid} ({name})")
            except HypervisorError:
                log.warning("Proxmox create_vm %r on %s failed", name, node, exc_info=True)
                raise
            except (httpx.HTTPError, KeyError, ValueError) as exc:
                log.warning("Proxmox create_vm %r on %s failed: %s", name, node, exc)
                raise HypervisorError(f"Proxmox VM create on {node} failed: {exc}") from exc
        log.info("Proxmox created + started VM %d (%s) on %s", vmid, name, node)
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
    - `boot_devices=[DISK, ETHERNET]` — disk first, network fallback (the vCenter analogue of Proxmox's
      `order=scsi0;net0`). An empty disk falls through to PXE on the first boot (the restore), then the same
      order boots the restored disk instead of PXE-looping forever.
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
        "boot_devices": [{"type": "DISK"}, {"type": "ETHERNET"}],
    }


class VCenterClient:
    """A thin async vCenter REST client (session auth). Login is Basic-auth POST /api/session returning a
    session id; every other call carries it as `vmware-api-session-id`."""

    def __init__(self, host: str, username: str, password: str, *, verify_tls: bool = False,
                 timeout: float = 30.0) -> None:
        self._host = host
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

    async def fingerprint(self) -> dict[str, Any] | None:
        """Identify the product WITHOUT credentials via the vSphere SOAP endpoint. POST RetrieveServiceContent
        to /sdk (no auth) and read AboutInfo: `productLineId` 'vpx' means a vCenter Server (as opposed to
        'embeddedEsx' for a standalone ESXi host, which the REST client here does not manage). Returns
        {"product":"vcenter","version","build","name"} or None.

        This is the canonical vSphere fingerprint (nmap's vmware-version, govc): product identity AND version
        come back with NO login, so detection never depends on which service account happens to be valid —
        the whole point of the operator's concern."""
        try:
            async with httpx.AsyncClient(verify=self._verify, timeout=self._timeout) as client:
                r = await client.post(f"https://{self._host}/sdk", content=_SOAP_SERVICE_CONTENT,
                                      headers={"Content-Type": "text/xml; charset=utf-8", "SOAPAction": ""})
        except httpx.HTTPError:
            return None
        line = _xml_text(r.text, "productLineId")
        if not line or "vpx" not in line.lower():   # embeddedEsx / gsx / other → not a vCenter
            return None
        return {"product": "vcenter", "version": _xml_text(r.text, "version"),
                "build": _xml_text(r.text, "build"), "name": _xml_text(r.text, "name")}

    async def probe(self) -> None:
        """Cheapest confirmation that these creds work against vCenter — a successful session login. detect()
        calls this only AFTER fingerprint() has already identified the product, purely to validate creds."""
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

# The vSphere SOAP RetrieveServiceContent request — returns AboutInfo (productLineId, version, build, name)
# with NO authentication. Same request nmap's vmware-version and govc use to fingerprint a vSphere endpoint.
_SOAP_SERVICE_CONTENT = (
    '<soap:Envelope xmlns:xsd="http://www.w3.org/2001/XMLSchema"'
    ' xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
    ' xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">'
    '<soap:Body>'
    '<RetrieveServiceContent xmlns="urn:internalvim25">'
    '<_this xsi:type="ManagedObjectReference" type="ServiceInstance">ServiceInstance</_this>'
    '</RetrieveServiceContent>'
    '</soap:Body></soap:Envelope>'
)


def _xml_text(text: str, tag: str) -> str | None:
    """Pull the text of the first <tag>…</tag> out of a SOAP/XML string, without an XML-parser dependency —
    AboutInfo fields are flat text elements, so a narrow regex is enough (and safe against odd payloads)."""
    m = re.search(rf"<{tag}>([^<]*)</{tag}>", text)
    return m.group(1).strip() if m else None


def _is_pve_envelope(r: httpx.Response) -> bool:
    """A Proxmox API response wraps everything in a JSON `{"data": …}` envelope — true even for the 401 from
    an unauthenticated /version. A secondary product signal to the `pve-api-daemon` Server banner."""
    try:
        return isinstance(r.json(), dict) and "data" in r.json()
    except ValueError:
        return False


async def detect(host: str, username: str, password: str, *, verify_tls: bool = False) -> str:
    """Identify the hypervisor at `host` by its PRODUCT identifier, then validate the credentials — returns
    'proxmox' | 'vcenter'.

    The product is decided by an UNAUTHENTICATED fingerprint (the vSphere SOAP AboutInfo on /sdk for vCenter,
    the pve-api-daemon surface on :8006 for Proxmox), never by which login happens to succeed. This is the
    operator's requirement: the same service account can be valid on both a Proxmox and a vCenter, so 'the
    login worked' is not proof of which product it is — the version/identifier surface is. The two probes hit
    different ports/protocols of the same host, so at most one product answers; if somehow both do, the host
    is genuinely ambiguous and we say so. Only once the product is known do we log in once to confirm the
    credentials are usable, so registering a host with bad creds still fails early and clearly."""
    prox = ProxmoxClient(host, username, password, verify_tls=verify_tls, timeout=15.0)
    vc = VCenterClient(host, username, password, verify_tls=verify_tls, timeout=15.0)
    prox_fp, vc_fp = await asyncio.gather(prox.fingerprint(), vc.fingerprint())

    if prox_fp and vc_fp:
        raise HypervisorError(
            f"{host!r} fingerprints as BOTH Proxmox (:8006) and vCenter (/sdk) — cannot disambiguate")
    if prox_fp:
        await prox.version()   # identity is settled; this only validates the credentials
        return "proxmox"
    if vc_fp:
        await vc.probe()       # identity is settled; this only validates the credentials
        return "vcenter"
    raise HypervisorError(
        f"no supported hypervisor identified at {host!r}: neither a Proxmox API on :8006 nor a vSphere "
        f"/sdk endpoint responded to an unauthenticated product probe")
