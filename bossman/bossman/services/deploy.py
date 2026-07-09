"""Server-driven SSH deploy of a new node agent (Block N-enroll).

The operator types a new host's IP/DNS in the UI; Bossman connects over SSH
with a pre-configured operator identity, copies the agent .deb, installs it,
and provisions a COMPLETE config.yaml itself — token, TLS server cert, and
Bossman's own public key pinned in tls.trusted_client_keys. Because Bossman
provisions the trust directly over the already-authenticated SSH channel,
there is no enrollment secret: the SSH login is the root of trust, and there
is nothing else to protect (the agent verifies Bossman's client cert; Bossman
polls with verify=False, the trust running the other way).

This deliberately does NOT reuse the `agentic-mcpd register` handshake: that
path exists for hosts an operator brings up by hand and points at Bossman,
and it intentionally does not wire up config.yaml. Here Bossman controls the
whole host, so it writes a known-good config in one shot rather than editing
one in place over SSH (which would be fragile).
"""

from __future__ import annotations

import os
import secrets
import shlex
from typing import TYPE_CHECKING

import asyncssh

from bossman.services import keys
from bossman.services.enrollment import EnrollRequest, enroll_agent

if TYPE_CHECKING:
    from sqlalchemy.ext.asyncio import AsyncSession

    from bossman.config import Settings
    from bossman.db.models import Agent

# Where the provisioned files land on the agent host. Fixed paths: these are
# the Bossman-managed identity, referenced by the config.yaml rendered below.
AGENT_CONFIG_PATH = "/etc/agentic-mcp/config.yaml"
AGENT_SERVER_CERT_PATH = "/etc/agentic-mcp/tls/server.crt"
AGENT_SERVER_KEY_PATH = "/etc/agentic-mcp/tls/server.key"
AGENT_BOSSMAN_KEY_PATH = "/etc/agentic-mcp/trusted/bossman.pub.pem"


class DeployError(Exception):
    """Raised when a deploy fails (misconfiguration, SSH/auth failure, a
    non-zero install step, or the service not coming back active) — always
    carries a human-readable message surfaced verbatim to the operator."""


def render_agent_config(*, token: str, listen_port: int, write: bool) -> str:
    """The complete config.yaml Bossman writes onto a freshly-deployed agent.
    Pure (no I/O) so it is unit-testable. tls.enabled with a self-signed
    server cert Bossman generated, plus Bossman's public key pinned as the
    single trusted client key — so Bossman (and only Bossman) can reach
    /api/v1/ and /mcp over mTLS."""
    return f"""# Managed by Bossman (server-driven deploy — Block N-enroll).
# Regenerated on every re-deploy; hand edits will be overwritten.
listen: "0.0.0.0:{listen_port}"
token: "{token}"
write: {"true" if write else "false"}

tls:
  enabled: true
  cert_file: {AGENT_SERVER_CERT_PATH}
  key_file: {AGENT_SERVER_KEY_PATH}
  trusted_client_keys:
    - name: bossman
      public_key_path: {AGENT_BOSSMAN_KEY_PATH}

ebpf:
  enabled: true

db:
  driver: sqlite
  path: /var/lib/agentic-mcp/agentic-mcp.db

pam:
  enabled: true
  service: agentic-mcp

ui:
  enabled: true

tools_dir: /etc/agentic-mcp/tools.d
commands_file: /etc/agentic-mcp/commands.yaml
"""


def _install_script(*, staging: str, deb_name: str, use_sudo: bool) -> str:
    """The one shell script run on the target: install the .deb, move the
    Bossman-provisioned files into /etc with correct perms, clean up, and
    restart. `install -m` sets ownership to root (we run as root/sudo) and
    the mode atomically. The final is-active is the success signal."""
    body = f"""set -e
dpkg -i {shlex.quote(staging + "/" + deb_name)}
mkdir -p /etc/agentic-mcp/tls /etc/agentic-mcp/trusted
install -m 0600 {shlex.quote(staging + "/server.key")} {shlex.quote(AGENT_SERVER_KEY_PATH)}
install -m 0644 {shlex.quote(staging + "/server.crt")} {shlex.quote(AGENT_SERVER_CERT_PATH)}
install -m 0644 {shlex.quote(staging + "/bossman.pub.pem")} {shlex.quote(AGENT_BOSSMAN_KEY_PATH)}
install -m 0600 {shlex.quote(staging + "/config.yaml")} {shlex.quote(AGENT_CONFIG_PATH)}
rm -rf {shlex.quote(staging)}
systemctl restart agentic-mcp.service
systemctl is-active agentic-mcp.service
"""
    return body


async def _run(conn: asyncssh.SSHClientConnection, cmd: str, *, sudo_password: str | None) -> str:
    """Runs cmd, feeding sudo_password on stdin when set (for `sudo -S`).
    Raises DeployError with captured stderr on any non-zero exit."""
    result = await conn.run(cmd, input=(sudo_password + "\n") if sudo_password else None, check=False)
    if result.exit_status != 0:
        stderr = (result.stderr or "").strip()
        stdout = (result.stdout or "").strip()
        raise DeployError(f"step failed (exit {result.exit_status}): {cmd}\n{stderr or stdout}")
    return result.stdout or ""


async def deploy_and_enroll(
    session: AsyncSession,
    settings: Settings,
    host: str,
    *,
    port: int | None = None,
    write: bool | None = None,
) -> Agent:
    """Deploy the agent onto `host` over SSH and record it as an enrolled
    Agent. Returns the upserted Agent (committed by the caller's session
    lifecycle — this function flushes; the route commits)."""
    host = host.strip()
    if not host:
        raise DeployError("host must not be empty")
    if not settings.deploy_ssh_user:
        raise DeployError("server-driven deploy is not configured (set BOSSMAN_DEPLOY_SSH_USER)")
    if not settings.agent_deb_path:
        raise DeployError("server-driven deploy is not configured (set BOSSMAN_AGENT_DEB_PATH)")
    if not os.path.isfile(settings.agent_deb_path):
        raise DeployError(f"agent .deb not found at {settings.agent_deb_path}")

    listen_port = port or settings.agent_listen_port
    do_write = settings.agent_deploy_write if write is None else write

    # Bossman's own client identity (the key the agent will pin) + a fresh
    # server identity for the agent + its bearer token.
    keys.ensure_client_keypair(settings.client_key_path, settings.client_cert_path)
    bossman_pub_pem = keys.own_public_key_pem(settings.client_cert_path)
    server_key_pem, server_cert_pem = keys.self_signed_server_pair(host)
    token = secrets.token_hex(32)
    config_yaml = render_agent_config(token=token, listen_port=listen_port, write=do_write)

    # A per-deploy staging dir under the SSH user's home (writable without
    # root); the install script moves everything into /etc as root.
    staging = f"agentic-mcp-deploy-{secrets.token_hex(8)}"
    deb_name = "agent.deb"
    is_root = settings.deploy_ssh_user == "root"
    sudo_prefix = "" if is_root else "sudo -S -p '' "
    sudo_password = None if is_root else (settings.deploy_sudo_password or settings.deploy_ssh_password or None)

    connect_kwargs: dict = {
        "host": host,
        "port": settings.deploy_ssh_port,
        "username": settings.deploy_ssh_user,
        "known_hosts": None,  # test/inventory hosts use ad-hoc keys; TOFU is out of scope for v1
        # Bounded connect so a firewalled/black-holed host fails fast with a
        # clean DeployError instead of hanging the HTTP request indefinitely.
        "connect_timeout": 20,
    }
    if settings.deploy_ssh_key_path:
        connect_kwargs["client_keys"] = [settings.deploy_ssh_key_path]
    elif settings.deploy_ssh_password:
        connect_kwargs["password"] = settings.deploy_ssh_password
    else:
        raise DeployError("no SSH auth configured (set BOSSMAN_DEPLOY_SSH_KEY or BOSSMAN_DEPLOY_SSH_PASSWORD)")

    try:
        async with asyncssh.connect(**connect_kwargs) as conn:
            await _run(conn, f"mkdir -p {shlex.quote(staging)}", sudo_password=None)
            async with conn.start_sftp_client() as sftp:
                await sftp.put(settings.agent_deb_path, f"{staging}/{deb_name}")
                for name, data in (
                    ("server.key", server_key_pem),
                    ("server.crt", server_cert_pem),
                    ("bossman.pub.pem", bossman_pub_pem),
                    ("config.yaml", config_yaml.encode()),
                ):
                    async with sftp.open(f"{staging}/{name}", "wb") as f:
                        await f.write(data)
            # Resolve the staging dir to an absolute path so the root-run
            # install script (whose cwd/HOME differ) can still find it.
            home = (await _run(conn, "pwd", sudo_password=None)).strip()
            abs_staging = f"{home}/{staging}"
            script = _install_script(staging=abs_staging, deb_name=deb_name, use_sudo=not is_root)
            active = await _run(
                conn,
                f"{sudo_prefix}sh -c {shlex.quote(script)}",
                sudo_password=sudo_password,
            )
            if active.strip() != "active":
                raise DeployError(f"service did not come back active (state: {active.strip() or 'unknown'})")
    except (asyncssh.Error, OSError) as exc:
        raise DeployError(f"SSH deploy to {host} failed: {exc}") from exc

    # Record it — reuse the enroll upsert with an empty secret (no secret in
    # the SSH-deploy model; enroll_agent's constant-time compare("","") is
    # True). Upserts by name, so a re-deploy refreshes the token/address.
    agent = await enroll_agent(
        session,
        "",
        EnrollRequest(name=host, enroll_secret="", token=token, address=f"{host}:{listen_port}"),
    )
    return agent
