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
