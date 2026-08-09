"""Drive the nested-virt QEMU lab that lives inside the pxe container.

Bossman never runs QEMU itself — it shells into the pxe container with
``docker exec <pxe_container> vm-control.sh <cmd> …`` (see deploy/pxe/vm-control.sh),
which encapsulates the qemu-system-x86_64 / websockify command lines. This module is
the thin, testable seam: it builds the argv, runs it, and parses the JSON that
``list`` returns. Everything hardware-bound (/dev/kvm, the ens19 bridge) lives in the
script and the compose wiring, not here.

The endpoints in api/vm.py 503 when ``settings.pxe_container`` is empty, so a
deployment without the pxe profile simply has no lab.
"""

from __future__ import annotations

import asyncio
import json
import re
import shlex
from typing import Awaitable, Callable

from bossman.config import get_settings

# Injectable spawn (argv) -> (returncode, stdout, stderr), so tests can drive the
# parsing/argv logic without a docker daemon. Mirrors services/chat_backend.py.
Spawn = Callable[[list[str]], Awaitable[tuple[int, str, str]]]

# VM names are used as directory names inside the container and in kill patterns;
# keep them to a safe charset so a name can never inject shell/path tricks.
_NAME_RE = re.compile(r"^[a-zA-Z0-9._-]{1,64}$")
# A MAC as QEMU wants it (six colon-separated hex octets).
_MAC_RE = re.compile(r"^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$")


class VmLabError(RuntimeError):
    """A vm-control invocation failed or the lab is not configured."""


async def _default_spawn(argv: list[str]) -> tuple[int, str, str]:
    try:
        proc = await asyncio.create_subprocess_exec(
            *argv,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
    except FileNotFoundError as exc:
        # e.g. the docker CLI isn't in this image — surface it as a clean lab error (400), not a 500.
        raise VmLabError(f"{argv[0]!r} not found (is the docker CLI installed in the bossman image?)") from exc
    out, err = await proc.communicate()
    return proc.returncode or 0, out.decode("utf-8", "replace"), err.decode("utf-8", "replace")


def _control_argv(args: list[str]) -> list[str]:
    """`docker exec <container> vm-control.sh <args…>` — raises if the lab is off."""
    settings = get_settings()
    if not settings.pxe_container:
        raise VmLabError("PXE lab is not configured (BOSSMAN_PXE_CONTAINER is empty)")
    return [settings.docker_bin, "exec", settings.pxe_container, "vm-control.sh", *args]


async def _run(args: list[str], *, spawn: Spawn | None = None) -> str:
    spawn = spawn or _default_spawn
    argv = _control_argv(args)
    rc, out, err = await spawn(argv)
    if rc != 0:
        raise VmLabError(f"vm-control {shlex.join(args)} failed (rc={rc}): {err.strip() or out.strip()}")
    return out.strip()


def _require_name(name: str) -> str:
    if not _NAME_RE.match(name):
        raise VmLabError(f"invalid VM name {name!r} (allowed: letters, digits, . _ -)")
    return name


async def install(name: str, iso: str, disk: str, disk_gib: int = 40, *, spawn: Spawn | None = None) -> str:
    """Boot an installer ISO with a fresh disk; the operator drives it over noVNC."""
    _require_name(name)
    _require_name(disk)
    if not iso or "/" in iso:
        raise VmLabError("iso must be a bare filename in the ISO dir")
    return await _run(["start-install", name, iso, disk, str(int(disk_gib))], spawn=spawn)


async def pxe_test(name: str, mac: str, disk: str, disk_gib: int = 60, *, spawn: Spawn | None = None) -> str:
    """Diskless-boot a target on the ens19 bridge so it PXE-restores the active template."""
    _require_name(name)
    _require_name(disk)
    if not _MAC_RE.match(mac):
        raise VmLabError(f"invalid MAC {mac!r}")
    return await _run(["start-pxe-test", name, mac, disk, str(int(disk_gib))], spawn=spawn)


async def stop(name: str, *, spawn: Spawn | None = None) -> str:
    return await _run(["stop", _require_name(name)], spawn=spawn)


async def list_vms(*, spawn: Spawn | None = None) -> list[dict]:
    out = await _run(["list"], spawn=spawn)
    try:
        data = json.loads(out or "[]")
    except json.JSONDecodeError as exc:  # pragma: no cover - defensive
        raise VmLabError(f"vm-control list returned non-JSON: {out!r}") from exc
    return data if isinstance(data, list) else []


# ── Importing an existing disk image (import-image.sh in the pxe container) ────────────────────────
async def list_sources(*, spawn: Spawn | None = None) -> list[str]:
    """Disk-image files staged in the lab's DISK_DIR (what the WebUI Import picker offers)."""
    settings = get_settings()
    if not settings.pxe_container:
        raise VmLabError("PXE lab is not configured (BOSSMAN_PXE_CONTAINER is empty)")
    argv = [settings.docker_bin, "exec", settings.pxe_container, "sh", "-c",
            "ls -1 /srv/templates 2>/dev/null | grep -Ei '\\.(vmdk|qcow2|raw|img)$' || true"]
    rc, out, err = await (spawn or _default_spawn)(argv)
    if rc != 0:
        raise VmLabError(f"listing import sources failed (rc={rc}): {err.strip() or out.strip()}")
    return [line.strip() for line in out.splitlines() if line.strip()]


async def start_import(source: str, image_id: str, token: str, bossman_url: str, *, spawn: Spawn | None = None) -> None:
    """Kick off import-image.sh DETACHED in the pxe container. It drives the whole capture itself (via
    the per-image token) and reports completion/failure back through the /images API, so Bossman does
    not block on the multi-GB partclone here."""
    settings = get_settings()
    if not settings.pxe_container:
        raise VmLabError("PXE lab is not configured (BOSSMAN_PXE_CONTAINER is empty)")
    if not source or "/" in source:
        raise VmLabError("source must be a bare filename in the lab's DISK_DIR")
    argv = [settings.docker_bin, "exec", "-d", settings.pxe_container,
            "import-image.sh", source, image_id, token, bossman_url]
    rc, out, err = await (spawn or _default_spawn)(argv)
    if rc != 0:
        raise VmLabError(f"could not launch import (rc={rc}): {err.strip() or out.strip()}")
