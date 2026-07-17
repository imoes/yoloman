"""Installation-wizard context (Block 4): tells the UI which OS family a host is,
which catalog packages are already installed (from the stored inventory — no live
call), and the family-resolved package names / service / config path per catalog
package. The wizard runs the seeded install-<pkg> runbooks; this endpoint only
supplies the family-specific values it overrides at run time."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException

from bossman.api.auth import get_current_identity
from bossman.config import Settings, get_settings
from bossman.db.models import Agent
from bossman.db.session import get_session
from sqlalchemy.ext.asyncio import AsyncSession

router = APIRouter()

# os-release ID / ID_LIKE token -> family.
_REDHAT = {"rhel", "centos", "rocky", "almalinux", "alma", "fedora", "ol", "oraclelinux", "redhat"}
_SUSE = {"suse", "opensuse", "sles", "sled", "opensuse-leap", "opensuse-tumbleweed"}


def _family(facts: dict) -> str:
    """Best-effort OS family from the stored facts. Prefers an explicit
    os_family fact (agent Block 7); falls back to the os-release id/id_like."""
    fam = str(facts.get("os_family") or "").lower()
    if fam in ("debian", "redhat", "suse"):
        return fam
    os = facts.get("os") or {}
    tokens = f"{os.get('id', '')} {os.get('id_like', '')} {os.get('distribution', '')}".lower()
    if any(t in tokens for t in _REDHAT):
        return "redhat"
    if any(t in tokens for t in _SUSE):
        return "suse"
    return "debian"


def _catalog(settings: Settings) -> dict:
    path = Path(settings.config_templates_dir).parent / "package_catalog.json"
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


@router.get("/api/v1/agents/{agent_id}/package-wizard/context")
async def wizard_context(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    agent = await session.get(Agent, agent_id)
    if agent is None:
        raise HTTPException(status_code=404, detail="agent not found")
    facts = agent.facts or {}
    family = _family(facts)
    catalog = _catalog(settings)

    # Installed versions keyed by package name (from the stored inventory).
    inv = {p.get("name"): p.get("version") for p in (facts.get("installed_packages") or []) if isinstance(p, dict)}

    installed: dict[str, str] = {}
    resolved: dict[str, dict] = {}
    for pkg, entry in catalog.items():
        fams = entry.get("families") or {}
        fam = fams.get(family) or fams.get("debian") or fams.get("ubuntu") or (next(iter(fams.values()), {}) if fams else {})
        resolved[pkg] = {"packages": fam.get("packages", []), "service": fam.get("service", ""),
                         "config_path": fam.get("config_path", "")}
        # Installed if ANY of the family's package names is present in inventory.
        for name in fam.get("packages", []):
            if name in inv:
                installed[pkg] = inv[name]
                break

    return {"family": family, "installed": installed, "catalog_resolved": resolved}
