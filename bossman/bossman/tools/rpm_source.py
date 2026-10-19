"""The RPM side of the qualify pipeline's package source — the twin of qualify_packages._deb_config.

One long-lived EL9 container (`agentic-rh-fetch`) with the repo metadata cached ONCE, and per package a
`docker exec` that downloads the .rpm, lists its %config files and unpacks it into a directory the host reads.
Nothing is installed and no scriptlet runs.

WHY A LONG-LIVED CONTAINER. The earlier scripts ran `docker run --rm almalinux:9` per batch, and every run paid
`dnf makecache` for BaseOS + AppStream + CRB + EPEL first — minutes, before the first package. Per package that
would be the whole cost. With the cache kept, a fetch is a download and an unpack.

`%config` IS THE STRONGEST SIGNAL and RPM gives it directly: `rpm -qcp` lists exactly the files the package
declares as configuration — better than Debian's conffiles plus a ranking heuristic.

UNPACKING: `rpm2archive` comes with rpm itself on EL8+; `cpio` is absent from almalinux:9 (measured), so it is
not the first choice. A missing unpacker is reported as an error, never as "the package ships nothing" — those
are different facts, and confusing them is how a package gets skipped as config-less.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import uuid
from dataclasses import dataclass, field
from pathlib import Path

IMAGE = os.environ.get("AGENTIC_EL_IMAGE", "almalinux:9")
CONTAINER = os.environ.get("AGENTIC_RH_CONTAINER", "agentic-rh-fetch")
RH_TMP = Path(os.environ.get("AGENTIC_DEB_TMP", "/data1/agentic-dev-tmp")) / "rpm"
_READY = RH_TMP / ".ready"

#: Same repo set the RedHat universe was measured from (rh_universe.py): BaseOS, AppStream, CRB and EPEL.
_PREPARE = (
    "set -e; dnf -q -y install epel-release dnf-plugins-core >/dev/null; "
    "dnf config-manager --set-enabled crb >/dev/null; dnf -q makecache >/dev/null; echo ready"
)

_FETCH = r"""
set -u
cd "/work/$1"
timeout 300 dnf download -q --destdir . "$2" >/dev/null 2>dnf.err || {
  # "No package X available" is a fact about the repos; anything else (network, timeout) may pass next time.
  if grep -qi "no package .* available\|no match for argument" dnf.err; then echo "not-in-repos" > status
  else echo "dnf-failed" > status; fi
  chown -R "$3" "/work/$1"; exit 0; }
rpm=$(ls -1 *.rpm 2>/dev/null | head -1)
[ -n "$rpm" ] || { echo "no-rpm" > status; exit 0; }
rpm -qcp "$rpm" > declared.txt 2>/dev/null || true
mkdir -p root
if command -v rpm2archive >/dev/null; then
  rpm2archive "$rpm" && tar xzf "$rpm.tgz" -C root 2>/dev/null
elif command -v cpio >/dev/null; then
  (cd root && rpm2cpio "../$rpm" | cpio -idmu --quiet)
else
  echo "no-unpacker" > status; exit 0
fi
rm -f ./*.rpm ./*.tgz
echo ok > status
chown -R "$3" "/work/$1"
"""


class RpmSourceError(RuntimeError):
    """The fetch machinery itself is broken (no docker, container will not start) — not a fact about a package."""


@dataclass
class RpmTree:
    """One unpacked package. `root` mirrors the filesystem the RPM would install; `declared` are its %config files."""
    package: str
    workdir: Path
    status: str
    declared: list[str] = field(default_factory=list)

    @property
    def root(self) -> Path:
        return self.workdir / "root"

    @property
    def ok(self) -> bool:
        return self.status == "ok"

    def cleanup(self) -> None:
        shutil.rmtree(self.workdir, ignore_errors=True)


def _docker(*argv: str, timeout: int = 900) -> subprocess.CompletedProcess:
    return subprocess.run(["docker", *argv], capture_output=True, text=True, timeout=timeout)


def ensure_container() -> None:
    """Start the fetch container and warm its dnf cache, once. Idempotent; raises RpmSourceError if impossible."""
    RH_TMP.mkdir(parents=True, exist_ok=True)
    try:
        running = _docker("inspect", "-f", "{{.State.Running}}", CONTAINER, timeout=30)
    except (OSError, subprocess.SubprocessError) as exc:
        raise RpmSourceError(f"docker not usable: {exc}") from exc
    if running.returncode == 0 and running.stdout.strip() == "true" and _READY.is_file():
        return
    _docker("rm", "-f", CONTAINER, timeout=60)
    _READY.unlink(missing_ok=True)
    proxy = os.environ.get("YOLOMAN_HTTP_PROXY") or os.environ.get("https_proxy") or ""
    env = ["-e", f"http_proxy={proxy}", "-e", f"https_proxy={proxy}"] if proxy else []
    started = _docker("run", "-d", "--name", CONTAINER, *env, "-v", f"{RH_TMP}:/work",
                      IMAGE, "sleep", "infinity", timeout=300)
    if started.returncode != 0:
        raise RpmSourceError(f"cannot start {CONTAINER}: {started.stderr.strip()[:200]}")
    prep = _docker("exec", CONTAINER, "bash", "-c", _PREPARE, timeout=1800)
    if prep.returncode != 0 or "ready" not in prep.stdout:
        raise RpmSourceError(f"dnf makecache failed in {CONTAINER}: {prep.stderr.strip()[:300]}")
    _READY.write_text(IMAGE + "\n")


def fetch(package: str) -> RpmTree:
    """Download + unpack one package. The caller must call `.cleanup()`. Never raises for a package-level
    failure: that comes back as `status` ("dnf-failed", "no-rpm", "no-unpacker", "timeout")."""
    ensure_container()
    work_id = uuid.uuid4().hex[:12]
    workdir = RH_TMP / work_id
    workdir.mkdir(parents=True)
    owner = f"{os.getuid()}:{os.getgid()}"
    try:
        _docker("exec", CONTAINER, "bash", "-c", _FETCH, "fetch", work_id, package, owner, timeout=420)
    except subprocess.TimeoutExpired:
        return RpmTree(package, workdir, "timeout")
    status_file = workdir / "status"
    status = status_file.read_text().strip() if status_file.is_file() else "no-status"
    declared: list[str] = []
    if (workdir / "declared.txt").is_file():
        declared = [ln.strip() for ln in (workdir / "declared.txt").read_text().splitlines()
                    if ln.strip().startswith("/etc/")]
    return RpmTree(package, workdir, status, declared)


def man5_text(tree: RpmTree, *names: str) -> str | None:
    """A section-5 man page the package SHIPS ITSELF, rendered to text — the RedHat build's own documentation of
    its config, preferred over a Debian mirror's page for the same software."""
    mandir = tree.root / "usr/share/man/man5"
    if not mandir.is_dir():
        return None
    pages = sorted(mandir.iterdir())
    wanted = [p for p in pages if any(p.name.split(".5")[0] in (n, n.rsplit(".", 1)[0]) for n in names if n)]
    env = {**os.environ, "MANWIDTH": "100", "MANPAGER": "cat", "PAGER": "cat"}
    for page in wanted or pages[:1]:
        try:
            txt = subprocess.run(["man", "-l", str(page)], capture_output=True, text=True,
                                 env=env, timeout=60).stdout
        except (OSError, subprocess.SubprocessError):
            continue
        if txt.strip():
            return txt[:200000]
    return None
