"""Installation-wizard context (Block 4): tells the UI which OS family a host is,
which catalog packages are already installed (from the stored inventory — no live
call), and the family-resolved package names / service / config path per catalog
package. The wizard runs the seeded install-<pkg> runbooks; this endpoint only
supplies the family-specific values it overrides at run time."""

from __future__ import annotations

import json
import time
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
    if any(t in tokens for t in ("debian", "ubuntu", "raspbian", "linuxmint", "devuan", "kali")):
        return "debian"
    # Unknown is a named state, not Debian. A host enrolled seconds ago has no facts yet; calling it Debian gave
    # an AlmaLinux host Debian's unit names (chrony.service instead of chronyd — Bossman-path final run).
    return "unknown"


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
    # THE ENTRY EXISTS, ONLY ACROSS THE LINUX/WINDOWS LINE: a positive fact, not a gap. "No package names in any
    # family" was the wrong reason for IIS on a Debian host — the catalog names it exactly, for Windows.
    across = sorted(f for f, b in fams.items() if isinstance(b, dict) and not b.get("unavailable")
                    and ((f in _NEVER_SUBSTITUTES) != (family in _NEVER_SUBSTITUTES)))
    if across:
        only = " / ".join(a.title() if a != "redhat" else "RedHat" for a in across)
        return {}, {"family_match": "unavailable", "family_used": family, "installable": False,
                    "reason": f"{only}-only — not available on {family or 'this host'}."}
    return {}, {"family_match": "unknown", "family_used": "", "installable": False,
                "reason": "The catalog has no package names for this entry in any family."}


def _catalog(settings: Settings) -> dict:
    path = Path(settings.config_templates_dir).parent / "package_catalog.json"
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def _family_fields(settings: Settings) -> dict[tuple[str, str], list[str]]:
    """{(family, config path): the fields that family's own template has} — for templates whose meta.json names a
    `family`. A role renders that template on hosts of that family (nt_engine `@<family>:<path>`), and a value set for
    a field it lacks is refused there, so the wizard greys such fields out with the reason instead of letting the
    operator fill them in for nothing (squid on EL: 3 directives where Debian documents 207)."""
    root = Path(settings.config_templates_dir)
    cached = _FAMILY_FIELDS_CACHE.get(str(root))
    if cached and time.monotonic() - cached[0] < 60:   # ~5800 template dirs; read at most once a minute
        return cached[1]
    out: dict[tuple[str, str], list[str]] = {}
    for meta in root.glob("*/meta.json"):
        try:
            m = json.loads(meta.read_text())
            schema = json.loads((meta.parent / "schema.json").read_text())
        except (OSError, ValueError):
            continue
        if isinstance(m, dict) and m.get("family") and m.get("target_path") and isinstance(schema, dict):
            out[(m["family"], m["target_path"])] = sorted(schema)
    _FAMILY_FIELDS_CACHE[str(root)] = (time.monotonic(), out)
    return out


_FAMILY_FIELDS_CACHE: dict[str, tuple[float, dict]] = {}


@router.get("/api/v1/agents/{agent_id}/package-wizard/context")
async def wizard_context(
    agent_id: UUID,
    refresh: bool = False,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Everything the package wizard needs for one host in a single call.

    The catalogue entries that apply, what the host already has, and which templates bind to it — so
    the wizard opens with one round trip instead of fanning out. Read-only: it computes what *could*
    be configured and changes nothing.
    """
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
    family_fields = _family_fields(settings)
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
                         # The fields this family's OWN template has for the role's file, or None when the role's
                         # named template renders here. A form field outside the list would be refused on this host.
                         "family_fields": family_fields.get((family, fam.get("config_path", ""))),
                         **meta}
        # Installed if ANY of the family's package names is present in inventory.
        for name in fam.get("packages", []):
            if name in inv:
                installed[pkg] = inv[name]
                break

    return {"host": agent.name, "family": family, "installed": installed, "catalog_resolved": resolved}
