"""The hypervisor detection + Proxmox inventory client — mocked HTTP, so no live Proxmox is needed."""

import httpx
import pytest

from bossman.services import hypervisor
from bossman.services.hypervisor import HypervisorError, ProxmoxClient, detect

# A canned Proxmox API: ticket auth, /version, /nodes, /nodes/{n}/storage, /nodes/{n}/network.
_TICKET = {"data": {"ticket": "PVE:abc", "CSRFPreventionToken": "csrf"}}
_VERSION = {"data": {"version": "8.2.2", "release": "8.2"}}
_NODES = {"data": [{"node": "pve1", "status": "online"}]}
_STORAGE = {"data": [
    {"storage": "local-lvm", "type": "lvmthin", "content": "images,rootdir", "avail": 500 << 30, "total": 900 << 30},
    {"storage": "local", "type": "dir", "content": "vztmpl,iso", "avail": 100 << 30, "total": 200 << 30},  # no images → dropped
]}
_NETWORK = {"data": [
    {"iface": "vmbr0", "type": "bridge", "comments": "lan"},
    {"iface": "eno1", "type": "eth"},                              # not a bridge → dropped
    {"iface": "vmbr1", "type": "bridge", "comments": ""},
]}


def _proxmox_handler(request: httpx.Request) -> httpx.Response:
    path = request.url.path
    if path.endswith("/access/ticket"):
        return httpx.Response(200, json=_TICKET)
    if path.endswith("/version"):
        return httpx.Response(200, json=_VERSION)
    if path.endswith("/nodes"):
        return httpx.Response(200, json=_NODES)
    if path.endswith("/nodes/pve1/storage"):
        return httpx.Response(200, json=_STORAGE)
    if path.endswith("/nodes/pve1/network"):
        return httpx.Response(200, json=_NETWORK)
    return httpx.Response(404, json={"data": None})


def _client_with(handler, monkeypatch):
    """Force ProxmoxClient's httpx.AsyncClient onto a MockTransport running `handler`."""
    real_init = httpx.AsyncClient.__init__

    def patched(self, *a, **kw):
        kw["transport"] = httpx.MockTransport(handler)
        kw.pop("verify", None)
        real_init(self, *a, **kw)

    monkeypatch.setattr(httpx.AsyncClient, "__init__", patched)


async def test_detect_identifies_proxmox(monkeypatch):
    _client_with(_proxmox_handler, monkeypatch)
    assert await detect("pve.example", "root@pam", "pw") == "proxmox"


async def test_detect_raises_a_helpful_error_when_nothing_answers(monkeypatch):
    def dead(_request):
        return httpx.Response(401, json={"data": None})
    _client_with(dead, monkeypatch)
    with pytest.raises(HypervisorError) as exc:
        await detect("nope.example", "x", "y")
    assert "vCenter" in str(exc.value)  # names what is not wired up yet, not a bare failure


async def test_placement_lists_only_image_storages_and_bridges(monkeypatch):
    _client_with(_proxmox_handler, monkeypatch)
    place = await ProxmoxClient("pve.example", "root@pam", "pw").placement()
    assert place["kind"] == "proxmox"
    node = place["nodes"][0]
    assert node["node"] == "pve1"
    # only the images-capable storage survives; the iso/vztmpl one is dropped
    assert [s["name"] for s in node["storages"]] == ["local-lvm"]
    # only bridges, not physical NICs
    assert sorted(b["name"] for b in node["bridges"]) == ["vmbr0", "vmbr1"]


async def test_auth_failure_surfaces_as_hypervisor_error(monkeypatch):
    def unauth(_request):
        return httpx.Response(403, text="denied")
    _client_with(unauth, monkeypatch)
    with pytest.raises(HypervisorError):
        await ProxmoxClient("pve.example", "root@pam", "bad").version()


def test_proxmox_vm_config_bios_vs_uefi():
    """The config assembly is the subtle part: PXE net-first boot, virtio-rng entropy, and — only for UEFI —
    an EFI disk. Pure function, asserted directly."""
    from bossman.services.hypervisor import _proxmox_vm_config

    bios = _proxmox_vm_config(name="t", cores=2, memory_mb=2048, disk_gib=32, storage="local-lvm",
                              bridge="vmbr0", mac="52:54:00:aa:bb:cc", vlan=None, uefi=False)
    assert bios["boot"] == "order=net0"                       # PXE first
    assert bios["net0"] == "virtio=52:54:00:aa:bb:cc,bridge=vmbr0"
    assert bios["scsi0"] == "local-lvm:32"
    assert bios["rng0"] == "source=/dev/urandom"              # entropy device, always
    assert "bios" not in bios and "efidisk0" not in bios      # BIOS: no OVMF, no EFI disk

    uefi = _proxmox_vm_config(name="t", cores=4, memory_mb=4096, disk_gib=64, storage="ssd",
                              bridge="vmbr1", mac="52:54:00:11:22:33", vlan=42, uefi=True)
    assert uefi["bios"] == "ovmf"
    assert uefi["efidisk0"].startswith("ssd:1")               # EFI disk on the same storage
    assert uefi["net0"] == "virtio=52:54:00:11:22:33,bridge=vmbr1,tag=42"   # VLAN tag applied


def test_gen_mac_is_locally_administered_qemu_style():
    from bossman.services.hypervisor import gen_mac
    m = gen_mac()
    assert m.startswith("52:54:00:") and len(m.split(":")) == 6


async def test_create_vm_posts_config_and_starts(monkeypatch):
    """create_vm gets nextid, POSTs the qemu config, starts the VM, and returns our MAC + the vmid."""
    posted = {}

    def handler(request: httpx.Request) -> httpx.Response:
        path = request.url.path
        if path.endswith("/access/ticket"):
            return httpx.Response(200, json=_TICKET)
        if path.endswith("/cluster/nextid"):
            return httpx.Response(200, json={"data": "131"})
        if path.endswith("/nodes/pve1/qemu"):
            posted["config"] = dict(httpx.QueryParams(request.content.decode()))
            return httpx.Response(200, json={"data": "UPID:create"})
        if path.endswith("/nodes/pve1/qemu/131/status/start"):
            posted["started"] = True
            return httpx.Response(200, json={"data": "UPID:start"})
        return httpx.Response(404, json={"data": None})

    _client_with(handler, monkeypatch)
    res = await ProxmoxClient("pve", "root@pam", "pw").create_vm(
        "pve1", "web01", cores=2, memory_mb=2048, disk_gib=32, storage="local-lvm",
        bridge="vmbr0", uefi=True, mac="52:54:00:de:ad:be")
    assert res == {"vmid": 131, "mac": "52:54:00:de:ad:be"}
    assert posted["started"] is True
    assert posted["config"]["vmid"] == "131" and posted["config"]["bios"] == "ovmf"
    assert posted["config"]["net0"] == "virtio=52:54:00:de:ad:be,bridge=vmbr0"


# ---- vCenter -------------------------------------------------------------
_VC_HOSTS = [{"host": "host-12", "name": "esxi-a.lab", "connection_state": "CONNECTED"}]
_VC_DS = [{"datastore": "datastore-9", "name": "ds-ssd", "type": "VMFS", "free_space": 500 << 30, "capacity": 900 << 30}]
_VC_NET = [{"network": "dvportgroup-3", "name": "VM Network", "type": "DISTRIBUTED_PORTGROUP"}]
_VC_FOLDER = [{"folder": "group-v22", "name": "vm"}]
_VC_POOL = [{"resource_pool": "resgroup-8", "name": "Resources"}]


def _vcenter_handler(request: httpx.Request) -> httpx.Response:
    p = request.url.path
    if p.endswith("/api/session"):
        return httpx.Response(200, json="sess-abc123")
    if p.endswith("/api/vcenter/host"):
        return httpx.Response(200, json=_VC_HOSTS)
    if p.endswith("/api/vcenter/datastore"):
        return httpx.Response(200, json=_VC_DS)
    if p.endswith("/api/vcenter/network"):
        return httpx.Response(200, json=_VC_NET)
    if p.endswith("/api/vcenter/folder"):
        return httpx.Response(200, json=_VC_FOLDER)
    if p.endswith("/api/vcenter/resource-pool"):
        return httpx.Response(200, json=_VC_POOL)
    if p.endswith("/api/vcenter/vm"):
        return httpx.Response(200, json="vm-501")
    if "/power" in p:
        return httpx.Response(204)
    return httpx.Response(404, json=None)


async def test_detect_falls_through_to_vcenter(monkeypatch):
    """A host that isn't Proxmox but authenticates a vCenter session is detected as vcenter."""
    from bossman.services.hypervisor import VCenterClient

    def handler(request):
        # Proxmox probe (:8006) fails; vCenter session succeeds.
        if ":8006" in str(request.url):
            return httpx.Response(401, json={"data": None})
        return _vcenter_handler(request)
    _client_with(handler, monkeypatch)
    assert await detect("vc.lab", "administrator@vsphere.local", "pw") == "vcenter"


async def test_vcenter_placement_maps_to_nodes_storages_bridges(monkeypatch):
    from bossman.services.hypervisor import VCenterClient
    _client_with(_vcenter_handler, monkeypatch)
    pl = await VCenterClient("vc.lab", "u", "p").placement()
    assert pl["kind"] == "vcenter"
    node = pl["nodes"][0]
    assert node["node"] == "esxi-a.lab"                       # host → node
    assert [s["name"] for s in node["storages"]] == ["ds-ssd"]        # datastore → storage
    assert [b["name"] for b in node["bridges"]] == ["VM Network"]     # portgroup → bridge


def test_vcenter_vm_spec_pxe_and_firmware():
    from bossman.services.hypervisor import _vcenter_vm_spec
    spec = _vcenter_vm_spec(
        name="web01", guest_os="OTHER_64", cores=2, memory_mb=2048, disk_bytes=32 << 30,
        host_id="host-12", datastore_id="datastore-9", folder_id="group-v22",
        resource_pool_id="resgroup-8", network_id="dvportgroup-3",
        network_type="DISTRIBUTED_PORTGROUP", mac="52:54:00:aa:bb:cc", uefi=True)
    assert spec["boot"]["type"] == "EFI"
    assert spec["boot_devices"] == [{"type": "ETHERNET"}]     # PXE first
    assert spec["nics"][0]["mac_address"] == "52:54:00:aa:bb:cc"
    assert spec["nics"][0]["backing"] == {"type": "DISTRIBUTED_PORTGROUP", "network": "dvportgroup-3"}
    assert spec["placement"]["datastore"] == "datastore-9"
    # BIOS variant
    bios = _vcenter_vm_spec(name="x", guest_os="OTHER_64", cores=1, memory_mb=1024, disk_bytes=1 << 30,
                            host_id="h", datastore_id="d", folder_id="f", resource_pool_id="r",
                            network_id="n", network_type="STANDARD_PORTGROUP", mac="52:54:00:1:2:3", uefi=False)
    assert bios["boot"]["type"] == "BIOS"


async def test_vcenter_create_vm_resolves_names_and_starts(monkeypatch):
    from bossman.services.hypervisor import VCenterClient
    _client_with(_vcenter_handler, monkeypatch)
    res = await VCenterClient("vc.lab", "u", "p").create_vm(
        "esxi-a.lab", "web01", cores=2, memory_mb=2048, disk_gib=32,
        storage="ds-ssd", bridge="VM Network", uefi=True, mac="52:54:00:de:ad:be")
    assert res == {"vmid": "vm-501", "mac": "52:54:00:de:ad:be"}
