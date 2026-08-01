"""services/vm_lab — the argv/validation seam of the PXE nested-virt lab, no docker daemon.

A fake spawn captures the argv `docker exec … vm-control.sh …` would run, so we pin the command shape
and the input guards (name/MAC charset, unconfigured-lab error) without QEMU or a container.
"""

import asyncio

import pytest

from bossman.services import vm_lab


@pytest.fixture
def lab(monkeypatch):
    """Configure the lab and hand back a recorder for the argv it would exec."""
    monkeypatch.setenv("BOSSMAN_PXE_CONTAINER", "agentic-mcp-pxe")
    monkeypatch.setenv("BOSSMAN_DOCKER_BIN", "docker")
    calls: list[list[str]] = []

    async def spawn(argv):
        calls.append(argv)
        # `list` parses stdout as JSON; everything else just needs rc 0.
        return 0, ("[]" if argv[-1] == "list" else argv[-1]), ""

    return calls, spawn


def _run(coro):
    return asyncio.run(coro)


def test_install_argv(lab):
    calls, spawn = lab
    _run(vm_lab.install("tmpl-deb12", "debian-12.iso", "tmpl-deb12.raw", 40, spawn=spawn))
    assert calls[0] == [
        "docker", "exec", "agentic-mcp-pxe", "vm-control.sh",
        "start-install", "tmpl-deb12", "debian-12.iso", "tmpl-deb12.raw", "40",
    ]


def test_pxe_test_argv(lab):
    calls, spawn = lab
    _run(vm_lab.pxe_test("target-01", "52:54:00:ab:cd:ef", "target-01.raw", 60, spawn=spawn))
    assert calls[0][4:] == ["start-pxe-test", "target-01", "52:54:00:ab:cd:ef", "target-01.raw", "60"]


def test_list_parses_json(lab):
    _, spawn = lab

    async def spawn_json(argv):
        return 0, '[{"name":"a","display":0,"vnc_port":5900,"ws_port":6080,"kind":"install","disk":"a.raw"}]', ""

    out = _run(vm_lab.list_vms(spawn=spawn_json))
    assert out[0]["name"] == "a" and out[0]["ws_port"] == 6080


def test_stop_argv(lab):
    calls, spawn = lab
    _run(vm_lab.stop("target-01", spawn=spawn))
    assert calls[0][4:] == ["stop", "target-01"]


@pytest.mark.parametrize("bad", ["a b", "../etc", "a;rm", "a$x", "x" * 65, ""])
def test_bad_name_rejected(lab, bad):
    _, spawn = lab
    with pytest.raises(vm_lab.VmLabError):
        _run(vm_lab.install(bad, "d.iso", "d.raw", spawn=spawn))


@pytest.mark.parametrize("mac", ["nope", "52:54:00:ab:cd", "gg:54:00:ab:cd:ef"])
def test_bad_mac_rejected(lab, mac):
    _, spawn = lab
    with pytest.raises(vm_lab.VmLabError):
        _run(vm_lab.pxe_test("t", mac, "t.raw", spawn=spawn))


def test_iso_must_be_bare_filename(lab):
    _, spawn = lab
    with pytest.raises(vm_lab.VmLabError):
        _run(vm_lab.install("t", "sub/dir/d.iso", "t.raw", spawn=spawn))


def test_unconfigured_lab_raises(monkeypatch):
    monkeypatch.setenv("BOSSMAN_PXE_CONTAINER", "")
    with pytest.raises(vm_lab.VmLabError, match="not configured"):
        _run(vm_lab.list_vms(spawn=lambda a: None))


def test_nonzero_rc_raises(lab):
    _, _spawn = lab

    async def failing(argv):
        return 1, "", "boom"

    with pytest.raises(vm_lab.VmLabError, match="boom"):
        _run(vm_lab.stop("t", spawn=failing))
