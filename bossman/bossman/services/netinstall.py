"""Install a VM with its distribution's OWN network installer — Fedora, AlmaLinux, Debian, Ubuntu.

Why not the image restore: that pipeline is Debian-only (grub-install, initramfs-tools, dpkg) and needs a captured
golden image. An installer gives the current release of each distribution without one.

The flow, driven by `deploy_vm(install="<distro>[-<release>]")` (MCP) and the deploy wizard (REST), both through
services/vm_provision.deploy:

1. The VM is created; the hypervisor hands out the MAC.
2. `create()` mints the host's agent identity with the same `plan_offline_install` the image restore uses (one trust
   setup, not two), enrols it with an install downtime, renders the installer's configuration and stores a job
   keyed on the MAC.
3. GET /api/v1/netboot/config hands the pxe container, for every active job, what to fetch (installer kernel,
   initrd, stage2/ISO — mirrored once per release), which files to serve (the configuration, finish.sh) and the boot
   entry; the container writes pxelinux.cfg/01-<mac> for exactly this MAC and its DHCP answers only that MAC
   (services/netboot_dhcp.py).
4. The installer installs from the distribution's mirror (through the corporate proxy) and runs finish.sh — the ONE
   place the agent is put in place for every distribution: package from the pxe container, the pre-minted identity,
   the service enabled.
5. `reconcile()` marks the job `done` the first time the new agent reports — the installer never calls back, so
   there is one source for "it worked" — and `failed` with the reason after NETINSTALL_TIMEOUT of silence.

Each distribution is a driver below: how its newest release is found, how a package list is checked against its
repositories, what is fetched, what is rendered, what the boot line says. A missing package is refused before the
VM exists — measured 2026-10-18 with Fedora: an unknown package makes Anaconda stop and ASK, forever.
"""
from __future__ import annotations

import base64
import gzip
import ipaddress
import json
import re
import secrets
import shlex
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any

import httpx
from sqlalchemy import select

from bossman.db.models import Agent, NetinstallJob

NETINSTALL_TIMEOUT = timedelta(hours=2)
ACTIVE = ("pending", "installing")
#: Benchmark tools yoloman.benchmark needs, as each family names them (Fedora's rt-tests holds no binaries).
_BENCH_RPM = ["realtime-tests", "fio", "stress-ng", "curl"]
_BENCH_DEB = ["rt-tests", "fio", "stress-ng", "sysbench", "curl"]


class NetinstallError(Exception):
    def __init__(self, message: str, status: int = 409):
        super().__init__(message)
        self.status = status


@dataclass
class Release:
    distro: str
    release: str          # what the user names: "44", "10", "13", "26.04"
    label: str            # human: "Fedora 44", "AlmaLinux 10.2", "Debian 13.7 (trixie)", "Ubuntu 26.04.1 LTS"
    family: str           # redhat | debian
    urls: dict[str, str] = field(default_factory=dict)

    def as_dict(self) -> dict[str, Any]:
        return {"distro": self.distro, "release": self.release, "label": self.label, "family": self.family, **self.urls}


def _proxy(settings) -> str:
    return getattr(settings, "target_https_proxy", "") or getattr(settings, "target_http_proxy", "") or ""


def _http(settings) -> httpx.AsyncClient:
    proxy = _proxy(settings) or None
    return httpx.AsyncClient(timeout=120, follow_redirects=True, proxy=proxy, trust_env=proxy is None)


_INDEX_CACHE: dict[str, set[str]] = {}


async def _deb_index(c: httpx.AsyncClient, url: str) -> set[str]:
    """Package names of one Debian-style Packages.gz (cached per URL for the process)."""
    if url not in _INDEX_CACHE:
        r = await c.get(url)
        r.raise_for_status()
        text = gzip.decompress(r.content).decode("utf-8", "replace")
        _INDEX_CACHE[url] = set(re.findall(r"^Package: (\S+)$", text, re.M))
    return _INDEX_CACHE[url]


async def _rpm_dir(c: httpx.AsyncClient, url: str) -> set[str]:
    """Package names in one directory listing of .rpm files (cached per URL for the process)."""
    if url not in _INDEX_CACHE:
        r = await c.get(url)
        _INDEX_CACHE[url] = (set(re.findall(r'href="([^"/]+?)-[^-"/]+-[^-"/]+\.(?:x86_64|noarch)\.rpm"', r.text))
                             if r.status_code == 200 else set())
    return _INDEX_CACHE[url]


# ── drivers ─────────────────────────────────────────────────────────────────────────────────────────────────────

class Anaconda:
    """Fedora and AlmaLinux: kickstart, stage2 install.img served locally, firewall port opened."""

    family = "redhat"
    config_name = "ks.cfg"
    min_memory_mb = 2048
    cpu_model: str | None = None   # Proxmox CPU type the release needs; None = the hypervisor's default

    def fetch(self, rel: Release) -> list[dict[str, str]]:
        return [{"url": rel.urls["kernel"], "area": "tftp", "path": "vmlinuz"},
                {"url": rel.urls["initrd"], "area": "tftp", "path": "initrd.img"},
                {"url": rel.urls["stage2"], "area": "http", "path": "images/install.img"}]

    def boot(self, rel: Release, *, base: str, cfg_url: str, net: dict[str, Any], hostname: str, mirror_dir: str):
        iface = ipaddress.IPv4Interface(net["address"])
        # Everything the installer reads before its kickstart comes from the local segment — no proxy on this line:
        # with inst.proxy the installer sent even the local kickstart request to the corporate proxy (measured).
        args = [f"inst.ks={cfg_url}", f"inst.stage2={base}/{mirror_dir}", "inst.text",
                f"ip={iface.ip}::{net['gateway']}:{iface.netmask}:{hostname}::none"]
        if net.get("dns"):
            args.append(f"nameserver={net['dns'][0]}")
        return {"kernel": "vmlinuz", "initrd": "initrd.img", "append": " ".join(args)}

    def extra_repos(self, rel: Release) -> list[tuple[str, str]]:
        return []

    def render(self, rel, *, net, hostname, packages, proxy, finish_url, listen_port) -> str:
        iface = ipaddress.IPv4Interface(net["address"])
        dns = ",".join(net.get("dns") or [])
        p = f" --proxy={proxy}" if proxy else ""
        repos = [f"url --url={rel.urls['repo']}{p}"] + [f"repo --name={n} --baseurl={u}{p}" for n, u in self.extra_repos(rel)]
        return "\n".join([
            "# Generated by Bossman (services/netinstall.py)",
            "text", "reboot", *repos,
            "lang en_US.UTF-8", "keyboard us", "timezone Europe/Berlin --utc",
            f"network --bootproto=static --device=link --ip={iface.ip} --netmask={iface.netmask} --gateway={net['gateway']}"
            + (f" --nameserver={dns}" if dns else "") + f" --hostname={hostname} --activate",
            "rootpw --lock", "selinux --enforcing", f"firewall --enabled --port={listen_port}:tcp",
            "zerombr", "clearpart --all --initlabel", "autopart --type=lvm --nohome", "bootloader --timeout=1",
            "services --enabled=sshd", "",
            "%packages", "@core", *packages, "%end", "",
            "%post --log=/root/bossman-finish.log",
            f"curl -fsS --noproxy '*' {shlex.quote(finish_url)} | sh",
            "%end", "",
        ])


class Fedora(Anaconda):
    name = "fedora"
    title = "Fedora"
    index = "https://dl.fedoraproject.org/pub/fedora/linux/releases/"
    # Fedora ships the scx schedulers as single packages — there is no scx-scheds (measured on Fedora 44).
    default_packages = ["scx_rusty", "scx_c_schedulers", "sysbench", *_BENCH_RPM]

    def _urls(self, release: str) -> dict[str, str]:
        repo = f"https://dl.fedoraproject.org/pub/fedora/linux/releases/{release}/Everything/x86_64/os"
        upd = f"https://dl.fedoraproject.org/pub/fedora/linux/updates/{release}/Everything/x86_64"
        return {"repo": repo, "updates": upd, "kernel": f"{repo}/images/pxeboot/vmlinuz",
                "initrd": f"{repo}/images/pxeboot/initrd.img", "stage2": f"{repo}/images/install.img"}

    async def resolve(self, c, release: str | None) -> Release:
        if release is None:
            idx = await c.get(self.index)
            idx.raise_for_status()
            for cand in sorted({int(m) for m in re.findall(r'href="(\d+)/"', idx.text)}, reverse=True)[:3]:
                if (await c.head(self._urls(str(cand))["kernel"])).status_code == 200:
                    release = str(cand)
                    break
            if release is None:
                raise NetinstallError(f"no Fedora release with a network installer at {self.index}", status=502)
        urls = self._urls(release)
        if (await c.head(urls["kernel"])).status_code != 200:
            raise NetinstallError(f"Fedora {release}: no installer at {urls['kernel']}", status=422)
        return Release("fedora", release, f"Fedora {release}", "redhat", urls)

    def extra_repos(self, rel):
        return [("updates", rel.urls["updates"])]

    async def known_packages(self, c, rel, letters) -> set[str]:
        names: set[str] = set()
        for letter in letters:
            names |= await _rpm_dir(c, f"{rel.urls['repo']}/Packages/{letter}/")
            names |= await _rpm_dir(c, f"{rel.urls['updates']}/Packages/{letter}/")
        return names


class Alma(Anaconda):
    name = "alma"
    title = "AlmaLinux"
    index = "https://repo.almalinux.org/almalinux/"
    cpu_model = "x86-64-v3"   # AlmaLinux 10 is built for x86-64-v3 (AVX2); on kvm64 the installer never comes up
    default_packages = list(_BENCH_RPM)

    def _urls(self, major: str) -> dict[str, str]:
        base = f"https://repo.almalinux.org/almalinux/{major}"
        repo = f"{base}/BaseOS/x86_64/os"
        return {"repo": repo, "appstream": f"{base}/AppStream/x86_64/os", "kernel": f"{repo}/images/pxeboot/vmlinuz",
                "initrd": f"{repo}/images/pxeboot/initrd.img", "stage2": f"{repo}/images/install.img"}

    async def resolve(self, c, release: str | None) -> Release:
        idx = await c.get(self.index)
        idx.raise_for_status()
        majors = sorted({int(m) for m in re.findall(r'href="(\d+)/"', idx.text)}, reverse=True)
        if release is None:
            for m in majors[:3]:
                if (await c.head(self._urls(str(m))["kernel"])).status_code == 200:
                    release = str(m)
                    break
            if release is None:
                raise NetinstallError(f"no AlmaLinux release with a network installer at {self.index}", status=502)
        urls = self._urls(release)
        if (await c.head(urls["kernel"])).status_code != 200:
            raise NetinstallError(f"AlmaLinux {release}: no installer at {urls['kernel']}", status=422)
        minors = sorted(set(re.findall(rf'href="({re.escape(release)}\.\d+)/"', idx.text)), key=lambda v: int(v.split(".")[1]))
        return Release("alma", release, f"AlmaLinux {minors[-1] if minors else release}", "redhat", urls)

    def extra_repos(self, rel):
        return [("AppStream", rel.urls["appstream"])]

    async def known_packages(self, c, rel, letters) -> set[str]:
        return await _rpm_dir(c, f"{rel.urls['repo']}/Packages/") | await _rpm_dir(c, f"{rel.urls['appstream']}/Packages/")


class Debian:
    """Debian stable: debian-installer netboot + preseed."""

    name = "debian"
    title = "Debian"
    family = "debian"
    config_name = "preseed.cfg"
    min_memory_mb = 1024
    cpu_model: str | None = None
    mirror = "https://deb.debian.org/debian"
    default_packages = list(_BENCH_DEB)

    async def resolve(self, c, release: str | None) -> Release:
        info = None
        for suite in ("stable", "oldstable"):
            r = await c.get(f"{self.mirror}/dists/{suite}/Release")
            r.raise_for_status()
            head = r.text.split("\nMD5Sum", 1)[0]
            ver = re.search(r"^Version: (\S+)", head, re.M).group(1)
            code = re.search(r"^Codename: (\S+)", head, re.M).group(1)
            if release is None or ver.split(".")[0] == release:
                info = (ver, code)
                break
        if info is None:
            raise NetinstallError(f"Debian {release} is neither stable nor oldstable", status=422)
        ver, code = info
        nb = f"{self.mirror}/dists/{code}/main/installer-amd64/current/images/netboot/debian-installer/amd64"
        return Release("debian", ver.split(".")[0], f"Debian {ver} ({code})", "debian",
                       {"codename": code, "kernel": f"{nb}/linux", "initrd": f"{nb}/initrd.gz",
                        "index": f"{self.mirror}/dists/{code}/main/binary-amd64/Packages.gz"})

    def fetch(self, rel):
        return [{"url": rel.urls["kernel"], "area": "tftp", "path": "linux"},
                {"url": rel.urls["initrd"], "area": "tftp", "path": "initrd.gz"}]

    def boot(self, rel, *, base, cfg_url, net, hostname, mirror_dir):
        iface = ipaddress.IPv4Interface(net["address"])
        host, _, domain = hostname.partition(".")
        args = ["auto=true", "priority=critical", f"url={cfg_url}", "interface=auto",
                "netcfg/disable_autoconfig=true", f"netcfg/get_ipaddress={iface.ip}", f"netcfg/get_netmask={iface.netmask}",
                f"netcfg/get_gateway={net['gateway']}", "netcfg/get_nameservers=" + ",".join(net.get("dns") or []),
                "netcfg/confirm_static=true", f"hostname={host}", f"domain={domain}",
                "locale=en_US.UTF-8", "keyboard-configuration/xkb-keymap=us"]
        return {"kernel": "linux", "initrd": "initrd.gz", "append": " ".join(args)}

    def render(self, rel, *, net, hostname, packages, proxy, finish_url, listen_port) -> str:
        iface = ipaddress.IPv4Interface(net["address"])
        host, _, domain = hostname.partition(".")

        def d(question: str, kind: str, value: str) -> str:
            return f"d-i {question} {kind} {value}"

        return "\n".join([
            "# Generated by Bossman (services/netinstall.py)",
            d("debian-installer/locale", "string", "en_US.UTF-8"), d("keyboard-configuration/xkb-keymap", "select", "us"),
            d("netcfg/choose_interface", "select", "auto"), d("netcfg/disable_autoconfig", "boolean", "true"),
            d("netcfg/get_ipaddress", "string", str(iface.ip)), d("netcfg/get_netmask", "string", str(iface.netmask)),
            d("netcfg/get_gateway", "string", net["gateway"]), d("netcfg/get_nameservers", "string", " ".join(net.get("dns") or [])),
            d("netcfg/confirm_static", "boolean", "true"), d("netcfg/get_hostname", "string", host),
            d("netcfg/get_domain", "string", domain), d("netcfg/hostname", "string", host),
            d("mirror/country", "string", "manual"), d("mirror/http/hostname", "string", "deb.debian.org"),
            d("mirror/http/directory", "string", "/debian"), d("mirror/http/proxy", "string", proxy or ""),
            d("passwd/root-login", "boolean", "false"), d("passwd/make-user", "boolean", "true"),
            d("passwd/user-fullname", "string", "Bossman"), d("passwd/username", "string", "bossman"),
            d("passwd/user-password-crypted", "password", "!"),
            d("clock-setup/utc", "boolean", "true"), d("time/zone", "string", "Europe/Berlin"),
            d("partman-auto/method", "string", "lvm"), d("partman-auto-lvm/guided_size", "string", "max"),
            d("partman-lvm/device_remove_lvm", "boolean", "true"), d("partman-md/device_remove_md", "boolean", "true"),
            d("partman-lvm/confirm", "boolean", "true"), d("partman-lvm/confirm_nooverwrite", "boolean", "true"),
            d("partman-auto/choose_recipe", "select", "atomic"),
            d("partman-partitioning/confirm_write_new_label", "boolean", "true"),
            d("partman/choose_partition", "select", "finish"), d("partman/confirm", "boolean", "true"),
            d("partman/confirm_nooverwrite", "boolean", "true"), d("apt-setup/cdrom/set-first", "boolean", "false"),
            "tasksel tasksel/first multiselect standard, ssh-server",
            d("pkgsel/include", "string", " ".join(packages)), d("pkgsel/upgrade", "select", "none"),
            "popularity-contest popularity-contest/participate boolean false",
            d("grub-installer/only_debian", "boolean", "true"), d("grub-installer/bootdev", "string", "default"),
            d("finish-install/reboot_in_progress", "note", ""),
            d("preseed/late_command", "string", f"in-target sh -c \"curl -fsS --noproxy '*' {finish_url} | sh\""),
            "",
        ])

    async def known_packages(self, c, rel, letters) -> set[str]:
        return await _deb_index(c, rel.urls["index"])


class Ubuntu:
    """Ubuntu's newest LTS: subiquity autoinstall. Ubuntu has had no other automated network installer since 20.04;
    autoinstall reads its configuration through cloud-init's NoCloud datasource INSIDE the installer — the installed
    system gets cloud-init disabled (finish.sh). The installer loads the live-server ISO into RAM: ≥ 6 GB memory."""

    name = "ubuntu"
    title = "Ubuntu"
    family = "debian"
    config_name = "user-data"
    # The initramfs downloads the whole live-server ISO (2.93 GB for 26.04.1) into its root tmpfs, which is half the
    # RAM. With 6 GB, wget stopped at 2.29 GB both times (nginx log) and the installer sat idle with nothing written;
    # 8 GB leaves room for the ISO plus the unpacked initrd.
    min_memory_mb = 8192
    cpu_model: str | None = None
    default_packages = list(_BENCH_DEB)

    async def resolve(self, c, release: str | None) -> Release:
        idx = await c.get("https://releases.ubuntu.com/")
        idx.raise_for_status()
        vers = sorted({v for v in re.findall(r'href="(\d{2}\.04)/"', idx.text) if int(v[:2]) % 2 == 0},
                      key=float, reverse=True)
        if release is not None and release not in vers:
            raise NetinstallError(f"Ubuntu {release} is not an LTS release on releases.ubuntu.com "
                                  f"(LTS: {', '.join(vers[:4])})", status=422)
        for v in ([release] if release else vers[:2]):
            page = await c.get(f"https://releases.ubuntu.com/{v}/")
            isos = sorted(set(re.findall(rf'href="(ubuntu-{re.escape(v)}(?:\.\d+)?-live-server-amd64\.iso)"', page.text)))
            if page.status_code == 200 and isos:
                iso = isos[-1]
                title = re.search(r"Ubuntu (\d{2}\.04(?:\.\d+)? LTS) \(([A-Za-z]+) ", page.text)
                code = title.group(2).lower() if title else ""
                nb = f"https://releases.ubuntu.com/{v}/netboot/amd64"
                return Release("ubuntu", v, f"Ubuntu {title.group(1) if title else v}", "debian",
                               {"codename": code, "kernel": f"{nb}/linux", "initrd": f"{nb}/initrd",
                                "iso": f"https://releases.ubuntu.com/{v}/{iso}", "iso_name": iso,
                                "index_main": f"http://archive.ubuntu.com/ubuntu/dists/{code}/main/binary-amd64/Packages.gz",
                                "index_universe": f"http://archive.ubuntu.com/ubuntu/dists/{code}/universe/binary-amd64/Packages.gz"})
        raise NetinstallError("no Ubuntu LTS with a live-server ISO found on releases.ubuntu.com", status=502)

    def fetch(self, rel):
        return [{"url": rel.urls["kernel"], "area": "tftp", "path": "linux"},
                {"url": rel.urls["initrd"], "area": "tftp", "path": "initrd"},
                {"url": rel.urls["iso"], "area": "http", "path": rel.urls["iso_name"]}]

    def boot(self, rel, *, base, cfg_url, net, hostname, mirror_dir):
        iface = ipaddress.IPv4Interface(net["address"])
        dns = (net.get("dns") or [""])[0]
        seed = cfg_url.rsplit("/", 1)[0] + "/"
        args = [f"ip={iface.ip}::{net['gateway']}:{iface.netmask}:{hostname.split('.')[0]}::none:{dns}",
                f"url={base}/{mirror_dir}/{rel.urls['iso_name']}", "autoinstall", f"ds=nocloud;s={seed}",
                "cloud-config-url=/dev/null"]
        return {"kernel": "linux", "initrd": "initrd", "append": " ".join(args)}

    def render(self, rel, *, net, hostname, packages, proxy, finish_url, listen_port) -> str:
        iface = ipaddress.IPv4Interface(net["address"])
        locked = "!" + secrets.token_hex(8)  # not a crypt hash, so no password can ever match: the user is locked
        doc = {"autoinstall": {
            "version": 1, "locale": "en_US.UTF-8", "keyboard": {"layout": "us"}, "timezone": "Europe/Berlin",
            "network": {"version": 2, "ethernets": {"primary": {
                "match": {"name": "en*"}, "addresses": [str(iface)],
                "routes": [{"to": "default", "via": net["gateway"]}],
                "nameservers": {"addresses": list(net.get("dns") or [])}}}},
            **({"proxy": proxy} if proxy else {}),
            "storage": {"layout": {"name": "lvm"}},
            "identity": {"hostname": hostname.split(".")[0], "username": "bossman", "password": locked},
            "ssh": {"install-server": True, "allow-pw": False},
            "packages": list(packages),
            "late-commands": [f"curtin in-target -- sh -c \"curl -fsS --noproxy '*' {finish_url} | sh\""],
            "shutdown": "reboot",
        }}
        return "#cloud-config\n" + json.dumps(doc, indent=1) + "\n"

    async def known_packages(self, c, rel, letters) -> set[str]:
        return await _deb_index(c, rel.urls["index_main"]) | await _deb_index(c, rel.urls["index_universe"])


DRIVERS = {d.name: d for d in (Fedora(), Alma(), Debian(), Ubuntu())}


def catalog() -> list[dict[str, Any]]:
    """What `install=` accepts — for the wizard and vm_hosts: name, title, family, default packages, minimum memory."""
    return [{"install": d.name, "title": d.title, "family": d.family, "default_packages": list(d.default_packages),
             "min_memory_mb": d.min_memory_mb, "cpu_model": d.cpu_model, "config": d.config_name} for d in DRIVERS.values()]


# ── shared steps ────────────────────────────────────────────────────────────────────────────────────────────────

def parse_install(spec: str) -> tuple[str, str | None]:
    """'fedora' → ('fedora', None = newest); 'fedora-44', 'alma-10', 'debian-13', 'ubuntu-26.04'."""
    distro, _, release = spec.strip().lower().partition("-")
    if distro == "almalinux":
        distro = "alma"
    if distro not in DRIVERS:
        raise NetinstallError(f"unknown install {spec!r} (known: {', '.join(sorted(DRIVERS))}[-<release>])", status=422)
    if release and not re.fullmatch(r"\d+(\.\d+)?", release):
        raise NetinstallError(f"release must be a version number, got {release!r}", status=422)
    return distro, release or None


async def resolve_release(settings, distro: str, release: str | None) -> dict[str, Any]:
    async with _http(settings) as c:
        return (await DRIVERS[distro].resolve(c, release)).as_dict()


def _release(install: dict[str, Any]) -> Release:
    known = {"distro", "release", "label", "family", "packages", "missing_packages"}
    return Release(install["distro"], install["release"], install.get("label", ""), install.get("family", ""),
                   {k: v for k, v in install.items() if k not in known and isinstance(v, str)})


async def missing_packages(settings, install: dict[str, Any], packages: list[str] | None) -> tuple[list[str], list[str]]:
    """(the package list that would be installed, those the distribution's repositories do not have)."""
    drv = DRIVERS[install["distro"]]
    pkgs = list(drv.default_packages if packages is None else packages)
    async with _http(settings) as c:
        names = await drv.known_packages(c, _release(install), sorted({p[0].lower() for p in pkgs if p}))
    return pkgs, [p for p in pkgs if p not in names]


def http_base(settings) -> str:
    base = (getattr(settings, "netinstall_http_base", "") or "").rstrip("/")
    if not base:
        raise NetinstallError("BOSSMAN_NETINSTALL_HTTP_BASE is not set (the pxe container's HTTP root, e.g. "
                              "http://192.0.2.130:8080) — the installer could not fetch its configuration", status=409)
    return base


def agent_rpm_url(settings) -> str:
    """Kept for callers that only need to know the HTTP base is set."""
    return f"{http_base(settings)}/agent.rpm"


def render_finish(*, family: str, base: str, files: list[tuple[str, bytes, int]], proxy: str, distro: str) -> str:
    """finish.sh — runs inside the installed system at the end of every installer. The agent package comes from the
    pxe container directly (never through the proxy, which does not reach the local segment — measured); its
    dependencies come through the proxy; the pre-minted identity is written AFTER the package, so the package's own
    first-install config is replaced."""
    kind = "rpm" if family == "redhat" else "deb"
    lines = ["#!/bin/sh", "# Generated by Bossman (services/netinstall.py): put the agent in place.", "set -e",
             f"curl -fsS --noproxy '*' -o /tmp/yoloman-agent.{kind} {shlex.quote(base + '/agent.' + kind)}"]
    if proxy:
        lines.append(f"export http_proxy={shlex.quote(proxy)} https_proxy={shlex.quote(proxy)}")
    if kind == "rpm":
        if proxy:
            lines.append(f"grep -q '^proxy=' /etc/dnf/dnf.conf || echo 'proxy={proxy}' >> /etc/dnf/dnf.conf")
        lines.append("dnf install -y /tmp/yoloman-agent.rpm")
    else:
        if proxy:
            lines.append("echo 'Acquire::http::Proxy \"%s\"; Acquire::https::Proxy \"%s\";' > /etc/apt/apt.conf.d/90bossman-proxy"
                         % (proxy, proxy))
        # In the installer's chroot nothing may start the daemon (it would run against the installer's kernel).
        lines += ["printf '#!/bin/sh\\nexit 101\\n' > /usr/sbin/policy-rc.d && chmod 755 /usr/sbin/policy-rc.d",
                  "DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/yoloman-agent.deb",
                  "rm -f /usr/sbin/policy-rc.d"]
    lines.append("rm -f /tmp/yoloman-agent.*")
    lines.append("mkdir -p /etc/agentic-mcp/tls /etc/agentic-mcp/trusted")
    for path, data, mode in files:
        lines.append(f"echo {base64.b64encode(data).decode()} | base64 -d > {shlex.quote(path)}")
        lines.append(f"chmod {mode:o} {shlex.quote(path)}")
    if family == "redhat":
        lines.append("restorecon -R /etc/agentic-mcp || true")
    if distro == "ubuntu":
        lines.append("touch /etc/cloud/cloud-init.disabled  # the installer needed cloud-init; the host does not")
    lines.append("systemctl enable yoloman-agent.service")
    return "\n".join(lines) + "\n"


async def create(session, settings, *, mac: str, hostname: str, network: dict[str, Any], install: dict[str, Any],
                 packages: list[str] | None, vm_host_id=None, vm_node: str | None = None, vm_id: str | None = None,
                 created_by: str) -> NetinstallJob:
    from bossman.services.deploy import (AGENT_BOSSMAN_KEY_PATH, AGENT_CONFIG_PATH, AGENT_SERVER_CERT_PATH,
                                         AGENT_SERVER_KEY_PATH)
    from bossman.services.offline_enroll import plan_offline_install, record_offline_agent

    drv = DRIVERS[install["distro"]]
    base = http_base(settings)
    dupe = await session.scalar(select(NetinstallJob).where(NetinstallJob.target_mac == mac,
                                                            NetinstallJob.status.in_(ACTIVE)))
    if dupe is not None:
        raise NetinstallError(f"{mac} already has an active install ({dupe.hostname}, {dupe.status})")
    agent = await session.scalar(select(Agent).where(Agent.name == hostname))
    if agent is not None and agent.enrollment_state == "enrolled" and agent.last_seen_at is not None:
        raise NetinstallError(f"{hostname} is a live host (its agent last reported {agent.last_seen_at.isoformat()})")
    ip = str(ipaddress.IPv4Interface(network["address"]).ip)
    plan = plan_offline_install(settings, hostname)
    by_name = {f.path.rsplit("/", 1)[1]: f for f in plan.files}
    files = [(AGENT_SERVER_KEY_PATH, by_name["server.key"].data, 0o600),
             (AGENT_SERVER_CERT_PATH, by_name["server.crt"].data, 0o644),
             (AGENT_BOSSMAN_KEY_PATH, by_name["bossman.pub.pem"].data, 0o644),
             (AGENT_CONFIG_PATH, by_name["config.yaml"].data, 0o600)]
    pkgs = list(drv.default_packages if packages is None else packages)
    rel = _release(install)
    cfg_dir = f"ks/{secrets.token_urlsafe(18)}"
    finish_url = f"{base}/{cfg_dir}/finish.sh"
    rendered = {
        drv.config_name: drv.render(rel, net=network, hostname=hostname, packages=pkgs, proxy=_proxy(settings),
                                    finish_url=finish_url, listen_port=plan.listen_port),
        "finish.sh": render_finish(family=drv.family, base=base, files=files, proxy=_proxy(settings), distro=drv.name),
    }
    if drv.name == "ubuntu":
        rendered["meta-data"] = f"instance-id: bossman-{secrets.token_hex(6)}\nlocal-hostname: {hostname.split('.')[0]}\n"
    # A row of an earlier attempt that never reported is re-enrolled in place (enroll_agent upserts by name).
    agent = await record_offline_agent(session, hostname, token=plan.token, listen_port=plan.listen_port,
                                       created_by=created_by)
    agent.address = f"{ip}:{plan.listen_port}"  # the name is not in DNS yet; the address the installer gives is
    job = NetinstallJob(target_mac=mac, hostname=hostname, distro=rel.distro, release=rel.release, network=network,
                        packages=pkgs, kickstart=json.dumps({"config": drv.config_name, "files": rendered,
                                                             "release": rel.as_dict()}),
                        ks_path=cfg_dir, agent_id=agent.id, vm_host_id=vm_host_id, vm_node=vm_node, vm_id=vm_id,
                        created_by=created_by)
    session.add(job)
    await session.commit()
    return job


def job_files(job: NetinstallJob) -> dict[str, Any]:
    """The rendered installer files of a job ({config, files, release}). A job written before the drivers existed
    holds a bare kickstart; it is read as Fedora's ks.cfg."""
    if job.kickstart.lstrip().startswith("{"):
        return json.loads(job.kickstart)
    return {"config": "ks.cfg", "files": {"ks.cfg": job.kickstart},
            "release": {"distro": job.distro, "release": job.release, "label": "", "family": "redhat",
                        **Fedora()._urls(job.release)}}


async def reconcile(session, now: datetime | None = None, job_ids: list | None = None) -> None:
    """done when the new agent has reported since the job was armed; failed after NETINSTALL_TIMEOUT.
    job_ids limits it to those jobs (a test passing its own clock must not age every job in the database)."""
    now = now or datetime.now(timezone.utc)
    q = select(NetinstallJob).where(NetinstallJob.status.in_(ACTIVE))
    if job_ids is not None:
        q = q.where(NetinstallJob.id.in_(job_ids))
    changed = False
    for j in (await session.scalars(q)).all():
        agent = await session.get(Agent, j.agent_id) if j.agent_id else None
        if agent is not None and agent.last_seen_at is not None and agent.last_seen_at > j.created_at:
            j.status, j.finished_at, changed = "done", now, True
        elif now - j.created_at > NETINSTALL_TIMEOUT:
            j.status, j.finished_at, changed = "failed", now, True
            j.error = f"the new host's agent did not report within {NETINSTALL_TIMEOUT} of arming the install"
    if changed:
        await session.commit()


async def boot_entries(session, settings) -> list[dict[str, Any]]:
    """What the pxe container needs for each active install: what to fetch, which files to serve, the boot entry."""
    base = (getattr(settings, "netinstall_http_base", "") or "").rstrip("/")
    out = []
    for j in (await session.scalars(select(NetinstallJob).where(NetinstallJob.status.in_(ACTIVE)))).all():
        drv = DRIVERS[j.distro]
        data = job_files(j)
        rel = _release(data["release"])
        mirror_dir = f"netinstall/{j.distro}-{j.release}"
        cfg_url = f"{base}/{j.ks_path}/{data['config']}"
        boot = drv.boot(rel, base=base, cfg_url=cfg_url, net=j.network, hostname=j.hostname, mirror_dir=mirror_dir)
        out.append({"mac": j.target_mac, "hostname": j.hostname, "distro": j.distro, "release": j.release,
                    "status": j.status, "mirror_dir": mirror_dir, "fetch": drv.fetch(rel),
                    "files": [{"path": f"{j.ks_path}/{name}", "content": content} for name, content in data["files"].items()],
                    "boot": {"kernel": f"{mirror_dir}/{boot['kernel']}", "initrd": f"{mirror_dir}/{boot['initrd']}",
                             "append": boot["append"]}})
    return out


async def mark_ready(session, mac: str) -> dict[str, Any]:
    """The pxe container has mirrored this MAC's installer and written its boot entry: start the VM (created
    stopped) and move the job from `pending` to `installing`. Idempotent — a job already installing is left alone."""
    from bossman.db.models import VmHost
    from bossman.services import hypervisor
    from bossman.services import vm_provision as vp

    job = await session.scalar(select(NetinstallJob).where(NetinstallJob.target_mac == mac,
                                                           NetinstallJob.status.in_(ACTIVE)))
    if job is None:
        return {"mac": mac, "action": "none", "reason": "no active install for this MAC"}
    if job.status != "pending":
        return {"mac": mac, "action": "none", "reason": f"install is already {job.status}"}
    if job.vm_host_id and job.vm_id:
        vm_host = await session.get(VmHost, job.vm_host_id)
        try:
            await vp.client_for(vm_host).vm_power(job.vm_id, "start", job.vm_node)
        except hypervisor.HypervisorError as exc:
            job.error = f"starting VM {job.vm_id} failed: {exc}"[:2000]
            await session.commit()
            return {"mac": mac, "action": "failed", "reason": job.error}
    job.status = "installing"
    await session.commit()
    return {"mac": mac, "action": "started", "vmid": job.vm_id}


async def status(session, hostname: str) -> dict[str, Any] | None:
    j = await session.scalar(select(NetinstallJob).where(NetinstallJob.hostname == hostname)
                             .order_by(NetinstallJob.created_at.desc()).limit(1))
    if j is None:
        return None
    return {"kind": "netinstall", "distro": j.distro, "release": j.release,
            "label": job_files(j)["release"].get("label") or None, "status": j.status, "mac": j.target_mac,
            "error": j.error, "armed_at": j.created_at.isoformat(),
            "finished_at": j.finished_at.isoformat() if j.finished_at else None}
