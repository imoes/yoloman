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
from bossman.api.plans import get_client_factory
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
    if fam in ("debian", "redhat", "suse", "windows"):
        return fam
    os = facts.get("os") or {}
    tokens = f"{os.get('id', '')} {os.get('id_like', '')} {os.get('distribution', '')}".lower()
    if any(t in tokens for t in _REDHAT):
        return "redhat"
    if any(t in tokens for t in _SUSE):
        return "suse"
    if "windows" in tokens:
        return "windows"
    return "debian"


#: Order in which another family's values may stand in for a missing one. Debian first because
#: the catalog's generators derive from Debian metadata, so it is the branch most likely present.
_FALLBACK_ORDER = ("debian", "ubuntu")

#: Families between which package names CANNOT stand in for each other, in either direction.
#:
#: The fallback exists because a Linux package name often transfers — nginx, postfix and samba are the same
#: word on Debian, RHEL and SUSE, measurably for 27 of the catalogue's roles. Between Linux and Windows
#: nothing transfers: `apt install nginx` is not a thing a Windows Server can be told, and `Web-Server` is not
#: a Debian package. So showing one family's names for the other is not a hedge, it is a wrong answer with a
#: caveat attached — and the honest outcome is `unknown`, which is visible as a gap in the catalogue.
_NEVER_SUBSTITUTES = frozenset({"windows"})


def _resolve_family(fams: dict, family: str) -> tuple[dict, dict]:
    """Pick the family branch to use, and say WHICH and WHY.

    Returns `(branch, meta)`, where meta classifies the outcome into one of four states that are
    exhaustive and mutually exclusive — every catalog entry lands in exactly one:

      exact        this family has its own branch. Nothing to explain.
      fallback     it does not; another family's values are shown, and `family_used` + `reason`
                   say so. Still installable: the operator may know the name transfers (it
                   measurably does for 27 of the roles — nginx, postfix, samba are the same
                   name everywhere), but they are no longer told a curated fact that isn't one.
      unavailable  the catalog states positively that this thing does not exist here (AppArmor on
                   RHEL, which ships SELinux). NOT installable — an impossible action is greyed
                   out with its reason, not attempted and explained afterwards.
      unknown      the entry has no families at all. Not installable, and visible as a gap in the
                   catalog rather than as an empty row.

    This exists because the generators used to write the Debian name into a `redhat` branch as
    well (build_package_catalog / classify_roles_features, both fixed). 78 of 90 redhat branches
    were verbatim copies, ~15 demonstrably wrong (cron→cronie, slapd→openldap-servers). The old
    resolution here — `fams.get(family) or fams.get("debian")` — could not help, because a
    fabricated branch is indistinguishable from a curated one: it satisfies `fams.get(family)`
    and the fallback never runs. Absence is the state that can be reasoned about.
    """
    branch = fams.get(family)
    if isinstance(branch, dict) and branch.get("unavailable"):
        meta = {"family_match": "unavailable", "family_used": family,
                "reason": str(branch["unavailable"]), "installable": False}
        if branch.get("instead"):
            meta["instead"] = branch["instead"]
        return {}, meta
    if isinstance(branch, dict):
        return branch, {"family_match": "exact", "family_used": family, "reason": "", "installable": True}

    for alt in (*_FALLBACK_ORDER, *sorted(fams)):
        # NO SUBSTITUTION ACROSS THE LINUX/WINDOWS LINE, in either direction. See _NEVER_SUBSTITUTES.
        if family in _NEVER_SUBSTITUTES or alt in _NEVER_SUBSTITUTES:
            continue
        if isinstance(fams.get(alt), dict) and not fams[alt].get("unavailable"):
            names = ", ".join(fams[alt].get("packages") or []) or "—"
            return fams[alt], {
                "family_match": "fallback", "family_used": alt, "installable": True,
                "reason": (f"No {family} entry in the catalog — showing the {alt} names ({names}). "
                           f"They may not exist on {family}."),
            }
    return {}, {"family_match": "unknown", "family_used": "", "installable": False,
                "reason": "The catalog has no package names for this entry in any family."}


def _catalog(settings: Settings) -> dict:
    path = Path(settings.config_templates_dir).parent / "package_catalog.json"
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


@router.get("/api/v1/agents/{agent_id}/package-wizard/context")
async def wizard_context(
    agent_id: UUID,
    refresh: bool = False,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    agent = await session.get(Agent, agent_id)
    if agent is None:
        raise HTTPException(status_code=404, detail="agent not found")
    # refresh=1 (used right after a wizard install): re-pull the installed
    # package list live instead of waiting for the poller's 6h cadence, so the
    # roles list flips to "Installed" immediately. Best-effort.
    if refresh and agent.address:
        try:
            res = await client_factory(agent, settings).call_tool("package_facts", {})
            pkgs = res.get("data") if isinstance(res, dict) else None
            if isinstance(pkgs, list):
                from datetime import datetime, timezone

                agent.facts = {**(agent.facts or {}), "installed_packages": pkgs,
                               "installed_packages_at": datetime.now(timezone.utc).isoformat()}
                await session.commit()
        except Exception:  # noqa: BLE001 — stale inventory is better than a 502
            pass
    facts = agent.facts or {}
    family = _family(facts)
    catalog = _catalog(settings)

    # Installed versions keyed by package name (from the stored inventory).
    inv = {p.get("name"): p.get("version") for p in (facts.get("installed_packages") or []) if isinstance(p, dict)}

    installed: dict[str, str] = {}
    resolved: dict[str, dict] = {}
    for pkg, entry in catalog.items():
        fam, meta = _resolve_family(entry.get("families") or {}, family)
        resolved[pkg] = {"packages": fam.get("packages", []), "service": fam.get("service", ""),
                         "config_path": fam.get("config_path", ""), "user": fam.get("user", ""),
                         # The Windows branch's own fields, projected under their own names rather than
                         # squeezed into `packages`: a ServerManager feature is not a package, and calling it
                         # one would make the client's install path pick apt. Absent for a Linux branch, which
                         # is what tells a caller which install verb applies.
                         "features": fam.get("features", []),
                         "feature_type": fam.get("feature_type", ""),
                         "include_management_tools": bool(fam.get("include_management_tools")),
                         **meta}
        # Installed if ANY of the family's package names is present in inventory.
        for name in fam.get("packages", []):
            if name in inv:
                installed[pkg] = inv[name]
                break

    return {"host": agent.name, "family": family, "installed": installed, "catalog_resolved": resolved}
