"""Pushing the agent package Bossman ships to one host — the ONE implementation behind the REST route
`POST /api/v1/agents/{id}/update-bundled` and the MCP tool `update_agent`.

The package is chosen by the host's OS family: redhat and suse get the .rpm (BOSSMAN_AGENT_RPM_PATH),
debian the .deb (BOSSMAN_AGENT_DEB_PATH). A host whose family is unknown or windows is refused with that
reason: before, "everything else" got the .deb, so a host enrolled seconds ago (no facts yet) or an RPM
host with unusual facts was sent a package its installer cannot read.
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from bossman.services.agent_client import AgentClientError


class AgentUpdateRefused(Exception):
    """The update cannot be pushed; the message says why. `status` is the HTTP status REST answers with."""

    def __init__(self, message: str, status: int = 409):
        super().__init__(message)
        self.status = status


@dataclass(frozen=True)
class BundledPackage:
    family: str
    kind: str  # deb | rpm
    path: str
    size: int
    sha256: str

    def as_dict(self) -> dict[str, Any]:
        return {"family": self.family, "package": self.kind, "path": self.path, "bytes": self.size, "sha256": self.sha256}


def bundled_package(agent, settings) -> BundledPackage:
    """Which package this host would get, or AgentUpdateRefused with the reason."""
    from bossman.api.package_wizard import _family

    if not agent.address:
        raise AgentUpdateRefused("agent has no direct address — cannot push an update to it directly")
    family = _family(agent.facts or {})
    if family in ("redhat", "suse"):
        kind, path = "rpm", settings.agent_rpm_path
    elif family == "debian":
        kind, path = "deb", settings.agent_deb_path
    else:
        raise AgentUpdateRefused(
            f"OS family of {agent.name!r} is {family!r} — no bundled Linux package fits (the host's facts may not "
            "have arrived yet); refusing rather than guessing .deb")
    if not path:
        raise AgentUpdateRefused(f"no bundled {kind} configured (set BOSSMAN_AGENT_{kind.upper()}_PATH)")
    p = Path(path)
    if not p.is_file():
        raise AgentUpdateRefused(f"bundled {kind} not found at {path}")
    data = p.read_bytes()
    return BundledPackage(family=family, kind=kind, path=path, size=len(data), sha256=hashlib.sha256(data).hexdigest())


async def push_bundled(agent, settings, client_factory) -> dict[str, Any]:
    """Send the bundled package to the agent's self-update endpoint; the agent installs it and restarts."""
    pkg = bundled_package(agent, settings)
    client = client_factory(agent, settings)
    try:
        result = await client.self_update(Path(pkg.path).read_bytes())
    except AgentClientError as exc:
        raise AgentUpdateRefused(str(exc), status=502) from exc
    return {"agent_id": str(agent.id), **pkg.as_dict(), "result": result}
