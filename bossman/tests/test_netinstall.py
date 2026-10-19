"""Network installs (services/netinstall.py): Fedora, AlmaLinux, Debian, Ubuntu — the rendered installer config, the
boot line, what is fetched, the shared finish.sh, the job keyed on the hypervisor's MAC, DHCP for that MAC only, and
done/failed derived from the agent.

DB-backed; the agent identity is minted into tmp paths; no mirror is contacted (the release dicts are given the way
resolve_release returns them).
"""
from __future__ import annotations

import json
import uuid
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import delete, select, text

from bossman.config import Settings
from bossman.db.models import Agent, Downtime, NetinstallJob
from bossman.services import netboot_dhcp, netinstall

TAG = uuid.uuid4().hex[:6]
NET = {"mode": "static", "address": "10.251.7.134/24", "gateway": "10.251.7.254", "dns": ["10.251.7.53"]}
BASE = "http://192.0.2.130:8080"
ORDER = ["fedora", "alma", "debian", "ubuntu"]

RELEASES = {
    "fedora": {"distro": "fedora", "release": "44", "label": "Fedora 44", "family": "redhat",
               **netinstall.Fedora()._urls("44")},
    "alma": {"distro": "alma", "release": "10", "label": "AlmaLinux 10.2", "family": "redhat",
             **netinstall.Alma()._urls("10")},
    "debian": {"distro": "debian", "release": "13", "label": "Debian 13.7 (trixie)", "family": "debian",
               "codename": "trixie", "kernel": "https://deb.debian.org/x/linux", "initrd": "https://deb.debian.org/x/initrd.gz",
               "index": "https://deb.debian.org/debian/dists/trixie/main/binary-amd64/Packages.gz"},
    "ubuntu": {"distro": "ubuntu", "release": "26.04", "label": "Ubuntu 26.04.1 LTS", "family": "debian",
               "codename": "resolute", "kernel": "https://releases.ubuntu.com/26.04/netboot/amd64/linux",
               "initrd": "https://releases.ubuntu.com/26.04/netboot/amd64/initrd",
               "iso": "https://releases.ubuntu.com/26.04/ubuntu-26.04.1-live-server-amd64.iso",
               "iso_name": "ubuntu-26.04.1-live-server-amd64.iso"},
}


@pytest.fixture
def settings(tmp_path):
    return Settings(database_url="postgresql+asyncpg://unused/unused", client_cert_path=str(tmp_path / "c.crt"),
                    client_key_path=str(tmp_path / "c.key"), netinstall_http_base=BASE,
                    target_https_proxy="http://proxy.example:80")


@pytest.fixture
async def cleanup(db_session):
    yield
    from bossman.api.agents import purge_agent_rows

    await db_session.execute(delete(NetinstallJob).where(NetinstallJob.hostname.like(f"kt-ni-{TAG}%")))
    ids = (await db_session.scalars(select(Agent.id).where(Agent.name.like(f"kt-ni-{TAG}%")))).all()
    # Deleting an agent cascades into compressed hypertables; the API's delete route lifts the same limit.
    await db_session.execute(text("SET LOCAL timescaledb.max_tuples_decompressed_per_dml_transaction = 0"))
    for agent_id in ids:
        await purge_agent_rows(db_session, agent_id)
    await db_session.execute(delete(Downtime).where(Downtime.agent_id.in_(ids)))
    await db_session.execute(delete(Agent).where(Agent.id.in_(ids)))
    await db_session.commit()


def _mac(i: int) -> str:
    return "bc:24:11:%s:%s:%02x" % (TAG[0:2], TAG[2:4], i)


def test_parse_install():
    assert netinstall.parse_install("fedora") == ("fedora", None)
    assert netinstall.parse_install("AlmaLinux-10") == ("alma", "10")
    assert netinstall.parse_install("ubuntu-26.04") == ("ubuntu", "26.04")
    with pytest.raises(netinstall.NetinstallError, match="unknown install"):
        netinstall.parse_install("gentoo")
    with pytest.raises(netinstall.NetinstallError, match="version number"):
        netinstall.parse_install("fedora-rawhide;x")


def test_catalog_names_every_distribution():
    cat = {c["install"]: c for c in netinstall.catalog()}
    assert set(cat) == set(ORDER)
    assert cat["ubuntu"]["min_memory_mb"] == 8192 and cat["debian"]["config"] == "preseed.cfg"
    assert "scx_rusty" in cat["fedora"]["default_packages"] and "realtime-tests" in cat["alma"]["default_packages"]


@pytest.mark.parametrize("distro", ORDER)
async def test_each_distribution_renders_boots_and_finishes(db_session, settings, cleanup, distro):
    host = f"kt-ni-{TAG}-{distro}.example.org"
    i = ORDER.index(distro)
    job = await netinstall.create(db_session, settings, mac=_mac(i), hostname=host, network=NET,
                                  install=RELEASES[distro], packages=None, created_by="test")
    data = json.loads(job.kickstart)
    drv = netinstall.DRIVERS[distro]
    cfg, finish = data["files"][drv.config_name], data["files"]["finish.sh"]
    finish_url = f"{BASE}/{job.ks_path}/finish.sh"

    # finish.sh: agent package straight from the pxe container (never the proxy), identity written after it.
    kind = "rpm" if drv.family == "redhat" else "deb"
    assert f"curl -fsS --noproxy '*' -o /tmp/yoloman-agent.{kind} {BASE}/agent.{kind}" in finish
    assert finish.index("--noproxy") < finish.index("export http_proxy")
    assert finish.index(f"install -y /tmp/yoloman-agent.{kind}") < finish.index("/etc/agentic-mcp/config.yaml")
    assert "systemctl enable yoloman-agent.service" in finish
    assert ("cloud-init.disabled" in finish) == (distro == "ubuntu")
    assert ("policy-rc.d" in finish) == (kind == "deb")

    # the installer config runs finish.sh and installs the package list
    assert finish_url in cfg
    for pkg in drv.default_packages:
        assert pkg in cfg
    if distro in ("fedora", "alma"):
        assert "--ip=10.251.7.134 --netmask=255.255.255.0 --gateway=10.251.7.254" in cfg
        assert "--proxy=http://proxy.example:80" in cfg and "rootpw --lock" in cfg
        assert ("repo --name=updates" in cfg) == (distro == "fedora")
        assert ("repo --name=AppStream" in cfg) == (distro == "alma")
    if distro == "debian":
        assert "d-i mirror/http/proxy string http://proxy.example:80" in cfg
        assert "d-i netcfg/get_ipaddress string 10.251.7.134" in cfg
    if distro == "ubuntu":
        doc = json.loads(cfg.split("\n", 1)[1])["autoinstall"]
        assert doc["network"]["ethernets"]["primary"]["addresses"] == ["10.251.7.134/24"]
        assert doc["proxy"] == "http://proxy.example:80" and doc["identity"]["password"].startswith("!")
        assert "meta-data" in data["files"]

    # boot entry and what the pxe container mirrors
    [entry] = [e for e in await netinstall.boot_entries(db_session, settings) if e["mac"] == _mac(i)]
    assert entry["mirror_dir"] == f"netinstall/{distro}-{RELEASES[distro]['release']}"
    append = entry["boot"]["append"]
    assert "proxy" not in append, "the boot line must not send local fetches to the proxy"
    assert {f["path"] for f in entry["files"]} >= {f"{job.ks_path}/{drv.config_name}", f"{job.ks_path}/finish.sh"}
    fetched = {f["path"] for f in entry["fetch"]}
    if distro in ("fedora", "alma"):
        assert "inst.ks=" in append and "inst.stage2=" in append and "images/install.img" in fetched
    if distro == "debian":
        assert "auto=true" in append and "priority=critical" in append and fetched == {"linux", "initrd.gz"}
        assert f"hostname=kt-ni-{TAG}-debian" in append and "domain=example.org" in append
    if distro == "ubuntu":
        assert "autoinstall" in append and f"ds=nocloud;s={BASE}/{job.ks_path}/" in append
        assert RELEASES["ubuntu"]["iso_name"] in fetched and f"url={BASE}/netinstall/ubuntu-26.04/" in append

    agent = await db_session.get(Agent, job.agent_id)
    assert agent.address == "10.251.7.134:18051"
    assert _mac(i) in (await netboot_dhcp.policy(db_session, enabled=True, open_minutes=15))["dhcp_macs"]


async def test_done_closes_the_dhcp_and_silence_fails(db_session, settings, cleanup):
    job = await netinstall.create(db_session, settings, mac=_mac(10), hostname=f"kt-ni-{TAG}-done", network=NET,
                                  install=RELEASES["fedora"], packages=[], created_by="test")
    with pytest.raises(netinstall.NetinstallError, match="already has an active install"):
        await netinstall.create(db_session, settings, mac=_mac(10), hostname=f"kt-ni-{TAG}-b", network=NET,
                                install=RELEASES["fedora"], packages=[], created_by="test")
    agent = await db_session.get(Agent, job.agent_id)
    agent.last_seen_at = datetime.now(timezone.utc) + timedelta(seconds=1)
    await db_session.commit()
    await netinstall.reconcile(db_session, job_ids=[job.id])
    await db_session.refresh(job)
    assert job.status == "done" and job.finished_at is not None
    assert _mac(10) not in (await netboot_dhcp.policy(db_session, enabled=True, open_minutes=15))["dhcp_macs"]

    silent = await netinstall.create(db_session, settings, mac=_mac(11), hostname=f"kt-ni-{TAG}-t", network=NET,
                                     install=RELEASES["fedora"], packages=[], created_by="test")
    await netinstall.reconcile(db_session, now=silent.created_at + netinstall.NETINSTALL_TIMEOUT + timedelta(minutes=1),
                               job_ids=[silent.id])
    await db_session.refresh(silent)
    assert silent.status == "failed" and "did not report" in silent.error


def test_http_base_is_required():
    s = Settings(database_url="postgresql+asyncpg://unused/unused", client_cert_path="/x", client_key_path="/y")
    with pytest.raises(netinstall.NetinstallError, match="BOSSMAN_NETINSTALL_HTTP_BASE"):
        netinstall.http_base(s)
