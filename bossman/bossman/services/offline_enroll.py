"""Install and enrol the agent into a filesystem that is not running yet.

The counterpart to `deploy.py`, which installs the agent over SSH onto a booted machine. During a
network install there is no booted machine to SSH into: the target's root is merely *mounted* in
the netboot helper, and the helper's own agent applies the desired state into it through the chroot
capability mode (`_target_root`). Putting the target's own agent in place is one of those
configuring actions — the same install the fleet already knows, only offline.

What is reused from the SSH path is the **identity provisioning and the rendered config**
(`render_agent_config`), not the transport. That matters: the token, the self-signed server pair and
Bossman's pinned public key are what make an agent *this* fleet's agent, and having two ways to mint
them would eventually mean two subtly different trust setups.

Three things are genuinely different offline, and each is a correctness issue rather than a detail:

* **`dpkg` must not start the service.** In a chroot the package's maintainer script calls the
  systemd helper, which either fails the install or starts a daemon inside the helper's namespace
  against the wrong kernel. Debian's documented mechanism for exactly this is `/usr/sbin/policy-rc.d`
  exiting 101; we install it around the `dpkg` call and remove it again.
* **`systemctl restart` is impossible and `is-active` would lie.** There is no init in the target, so
  the honest success signal is not "is it running" but "will it run" — `systemctl --root=/ enable`,
  verified with `is-enabled`. Measured on this host: `--root=/` takes the offline code path and needs
  no dbus.
* **The new host must not page while it is being built.** Since a stale agent now marks a host DOWN
  and CRITICAL, an agent row created before the machine has booted would alert on a host that is
  merely still installing. So enrolment schedules a host downtime across the install-and-boot window.
"""

from __future__ import annotations

import base64
import secrets
import shlex
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from bossman.services import keys
from bossman.services.enrollment import EnrollRequest, enroll_agent

from ..config import Settings
from ..db.models import Agent
from ..services.imaging import TARGET_ROOT, Step
from ..services.deploy import (
    AGENT_BOSSMAN_KEY_PATH,
    AGENT_CONFIG_PATH,
    AGENT_SERVER_CERT_PATH,
    AGENT_SERVER_KEY_PATH,
    DeployError,
    render_agent_config,
)
from ..services.monitoring import create_downtime

# Where the staging files land. A path *inside the target* because the chroot capability resolves
# every path against the target root — so this is what both the file writes and the install script
# see, with no translation in between.
STAGING_PARENT = "/var/tmp"

SERVICE_NAME = "agentic-mcp.service"
POLICY_RC_PATH = "/usr/sbin/policy-rc.d"
DEB_NAME = "agent.deb"

# How long the new host is exempt from alerting. Covers the rest of the restore plus the single
# reboot plus the first poll; deliberately generous, since an over-long downtime is a quiet host
# while a too-short one is a false page at 4am.
INSTALL_DOWNTIME = timedelta(minutes=45)


@dataclass(frozen=True)
class StagedFile:
    """One file the helper writes into the target before the install script runs."""

    path: str  # absolute *inside the target*
    data: bytes
    mode: int


@dataclass(frozen=True)
class OfflineInstall:
    """Everything needed to put the agent into a mounted target, as data.

    Pure so the whole plan is unit-testable without a target root, an agent or a chroot: the tests
    assert on the file set, the modes and the script text.
    """

    staging_dir: str
    files: tuple[StagedFile, ...]
    script: str
    token: str
    listen_port: int


def _policy_rc_d() -> bytes:
    """Deny every init action for the duration of the install (101 = "action forbidden by policy",
    which `invoke-rc.d` understands and does not treat as an error)."""
    return b"#!/bin/sh\n# Installed by Bossman for the duration of an offline agent install.\nexit 101\n"


def offline_install_script(*, staging: str, deb_name: str) -> str:
    """The script the helper's agent runs with `_target_root` set, so every argv executes inside the
    target. Paths are therefore plain absolute paths as the installed system will see them.

    Ends by printing `is-enabled`, which is the offline analogue of the SSH path's `is-active`: the
    strongest claim that can honestly be made about a system that is not running.
    """
    deb = shlex.quote(f"{staging}/{deb_name}")
    return f"""set -e
# Keep dpkg's maintainer scripts from starting the daemon in here — see module docstring.
install -m 0755 {shlex.quote(staging + "/policy-rc.d")} {shlex.quote(POLICY_RC_PATH)}
DEBIAN_FRONTEND=noninteractive dpkg -i {deb}
rm -f {shlex.quote(POLICY_RC_PATH)}
mkdir -p /etc/agentic-mcp/tls /etc/agentic-mcp/trusted
install -m 0600 {shlex.quote(staging + "/server.key")} {shlex.quote(AGENT_SERVER_KEY_PATH)}
install -m 0644 {shlex.quote(staging + "/server.crt")} {shlex.quote(AGENT_SERVER_CERT_PATH)}
install -m 0644 {shlex.quote(staging + "/bossman.pub.pem")} {shlex.quote(AGENT_BOSSMAN_KEY_PATH)}
install -m 0600 {shlex.quote(staging + "/config.yaml")} {shlex.quote(AGENT_CONFIG_PATH)}
rm -rf {shlex.quote(staging)}
# No init here, so enable-for-next-boot instead of restart, and report what can be verified.
systemctl --root=/ enable {SERVICE_NAME}
systemctl --root=/ is-enabled {SERVICE_NAME}
"""


def plan_offline_install(
    settings: Settings,
    host: str,
    *,
    port: int | None = None,
    write: bool | None = None,
) -> OfflineInstall:
    """Mint the target's identity and lay out the offline install.

    Only the small identity files are staged as data. The agent package is NOT among them: it is tens
    of megabytes and would have to travel as base64 inside a JSON checkin response, when the helper
    already has `curl` and an image store to fetch it from. `offline_install_steps` emits that fetch.
    """
    host = host.strip()
    if not host:
        raise DeployError("host must not be empty")

    listen_port = port or settings.agent_listen_port
    do_write = settings.agent_deploy_write if write is None else write

    keys.ensure_client_keypair(settings.client_key_path, settings.client_cert_path)
    bossman_pub_pem = keys.own_public_key_pem(settings.client_cert_path)
    server_key_pem, server_cert_pem = keys.self_signed_server_pair(host)
    token = secrets.token_hex(32)
    config_yaml = render_agent_config(token=token, listen_port=listen_port, write=do_write)

    staging = f"{STAGING_PARENT}/agentic-mcp-offline-{secrets.token_hex(8)}"
    files = (
        # 0600 for the private key and the config, which carries the bearer token — the same modes
        # the SSH install script sets, since the file lands on the same kind of system either way.
        StagedFile(f"{staging}/server.key", server_key_pem, 0o600),
        StagedFile(f"{staging}/server.crt", server_cert_pem, 0o644),
        StagedFile(f"{staging}/bossman.pub.pem", bossman_pub_pem, 0o644),
        StagedFile(f"{staging}/config.yaml", config_yaml.encode(), 0o600),
        StagedFile(f"{staging}/policy-rc.d", _policy_rc_d(), 0o755),
    )
    return OfflineInstall(
        staging_dir=staging,
        files=files,
        script=offline_install_script(staging=staging, deb_name=DEB_NAME),
        token=token,
        listen_port=listen_port,
    )


def offline_install_steps(plan: OfflineInstall, *, deb_url: str) -> list[Step]:
    """Turn the plan into steps the netboot helper executes, in order.

    The split between helper-side and chroot steps is not cosmetic — it is dictated by which binaries
    exist where. `curl` and `base64` are in the helper image because we put them there; the target is a
    minimal Debian that may well have neither. `dpkg`, `install`, `systemctl` are in the target, and
    that is exactly where the install has to run. So: fetch and stage from outside, install from inside.

    Emitted as `Step`s rather than a separate "files" channel so the ordering comes for free. These
    have to land *after* the restored filesystems are mounted, and a step list already expresses that;
    a side-channel of files to write "first" would not.
    """
    staged_root = f"{TARGET_ROOT}{plan.staging_dir}"
    steps = [
        Step(name="stage dir for the agent install", argv=("mkdir", "-p", staged_root)),
        # --retry because this is the one download that happens after the filesystems are already
        # written: failing here would leave a restored but un-enrolled machine.
        Step(
            name="fetch the agent package",
            argv=("curl", "-fsSL", "--retry", "5", "--retry-all-errors", "-o", f"{staged_root}/{DEB_NAME}", deb_url),
        ),
    ]
    for f in plan.files:
        target = f"{staged_root}/{f.path.rsplit('/', 1)[-1]}"
        # base64 through a pipe: no quoting hazards, no assumptions about the content being text, and
        # the key never appears as a shell argument where a `ps` would show it.
        encoded = base64.b64encode(f.data).decode()
        steps.append(
            Step(
                name=f"stage {f.path.rsplit('/', 1)[-1]}",
                shell=f"printf %s {shlex.quote(encoded)} | base64 -d > {shlex.quote(target)} "
                f"&& chmod {f.mode:04o} {shlex.quote(target)}",
            )
        )
    # The only step that runs inside the target, and the only one that needs to.
    steps.append(Step(name="install the agent into the target", shell=plan.script, chroot=True))
    return steps


def install_succeeded(output: str) -> bool:
    """True when the script's output ends in the enablement we asked for.

    Matches the SSH path's shape (last non-empty line), because `dpkg` writes plenty of its own
    output before it and only the final line is our signal.
    """
    lines = [ln.strip() for ln in output.splitlines() if ln.strip()]
    return bool(lines) and lines[-1] == "enabled"


async def record_offline_agent(
    session: AsyncSession,
    host: str,
    *,
    token: str,
    listen_port: int,
    now: datetime | None = None,
    downtime: timedelta = INSTALL_DOWNTIME,
    created_by: str | None = "netboot",
) -> Agent:
    """Enrol the target as a fleet member and shield it from alerting until it has booted.

    The downtime is the point of this function existing rather than the caller just calling
    `enroll_agent`: the agent row has to exist before the machine boots (that is how the booting
    agent is recognised at all), but a host with no agent report is now DOWN and CRITICAL. Without
    the window, every install would page for the minutes between enrolment and first boot.
    """
    agent = await enroll_agent(
        session,
        EnrollRequest(name=host, token=token, address=f"{host}:{listen_port}"),
    )
    start = now or datetime.now(timezone.utc)
    await create_downtime(
        session,
        agent_id=agent.id,
        service_name=None,  # whole host: nothing about it is meaningful mid-install
        starts_at=start,
        ends_at=start + downtime,
        comment="Network install in progress (bare-metal deployment)",
        created_by=created_by,
    )
    return agent


def target_agent_id(agent: Agent) -> UUID:
    """Small accessor kept so callers do not reach into the ORM object for the one field they need."""
    return agent.id
