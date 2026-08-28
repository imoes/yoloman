"""The Lego capability matcher — pure, model-free logic (like services/compliance.py).

Two layers:

  DERIVE (populates host_capabilities): from Agent.facts["installed_packages"] x package_catalog.json
  (which roles a host runs) x each role template's capabilities.json (what that role provides/requires).
  Reconciled per host like host labels — only 'derived' rows are touched, 'explicit' ones survive.

  MATCH (reads host_capabilities): answers the four questions the Blueprint editor / AI ask —
    - open_requirements(agent)      "what does this server still need?"
    - find_providers(requirement)   "who in the inventory provides it?" (backend-filtered, alias-aware)
    - roles_providing(capability)   "which role would a NEW server need?"
    - propose_wiring(consumer, provider) "fill both sides' fields" (consumer db_host=…, provider peer IP/DB)

No LLM at match time: this is deterministic set logic over the DB. The AI surface (MCP tool, chat tool)
calls the SAME functions, so one logic backs three interfaces.
"""
from __future__ import annotations

import json
import logging
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from bossman.config import Settings
from bossman.db.models import Agent, HostCapability

logger = logging.getLogger(__name__)


# ─────────────────────────────────────────────────────────── loaders (catalog / sidecars / vocabulary)


def _configs_root(settings: Settings) -> Path:
    """configs/ — the parent of config_templates/, holding package_catalog.json + capability_vocabulary.json."""
    return Path(settings.config_templates_dir).parent


def load_catalog(settings: Settings) -> dict:
    try:
        return json.loads((_configs_root(settings) / "package_catalog.json").read_text())
    except (OSError, ValueError):
        return {}


@lru_cache(maxsize=8)
def _vocab(root: str) -> dict:
    try:
        return json.loads((Path(root) / "capability_vocabulary.json").read_text())
    except (OSError, ValueError):
        return {"capabilities": {}, "backend_aliases": {}}


def load_vocabulary(settings: Settings) -> dict:
    return _vocab(str(_configs_root(settings)))


def load_template_capabilities(settings: Settings, template: str) -> dict | None:
    """Read config_templates/<template>/capabilities.json (the Lego contract). None if absent/invalid."""
    if not template:
        return None
    f = Path(settings.config_templates_dir) / template / "capabilities.json"
    if not f.is_file():
        return None
    try:
        obj = json.loads(f.read_text())
    except ValueError:
        return None
    return obj if isinstance(obj, dict) else None


# ─────────────────────────────────────────────────────────── family resolution + installed-role join


def family_of(facts: dict) -> str:
    """OS family from facts — mirrors api/package_wizard._family."""
    fam = (facts or {}).get("os_family")
    if isinstance(fam, str) and fam:
        return fam.lower()
    osr = (facts or {}).get("os_release") or {}
    tokens = f"{osr.get('id','')} {osr.get('id_like','')}".lower()
    for cand in ("debian", "ubuntu", "redhat", "rhel", "centos", "fedora", "suse", "windows"):
        if cand in tokens:
            return "redhat" if cand in ("rhel", "centos", "fedora") else ("debian" if cand == "ubuntu" else cand)
    # DEBIAN AS THE LAST RESORT IS A GUESS, and it was measurably the wrong one: the C# Windows agent reported
    # no inventory at all, so this line read a Windows Server as Debian and every family-dependent lookup
    # believed it. The guess stays for a LINUX host whose os-release is unhelpful (where it is usually right
    # and always harmless — the package names transfer), and api/package_wizard._resolve_family now refuses
    # to substitute across the Linux/Windows line in either direction.
    return "debian"


def installed_roles(facts: dict, catalog: dict) -> list[tuple[str, dict, dict]]:
    """Roles the host runs: (role_name, catalog_entry, resolved_family_dict). A catalog role counts as
    installed when ANY of its family-resolved package names appears in facts["installed_packages"] —
    the same rule as api/package_wizard.wizard_context."""
    inv = {p.get("name") for p in (facts or {}).get("installed_packages") or [] if isinstance(p, dict)}
    family = family_of(facts)
    out: list[tuple[str, dict, dict]] = []
    for role, entry in (catalog or {}).items():
        fams = entry.get("families") or {}
        # EXACT ONLY FOR WINDOWS: a Debian branch's package names cannot appear in a Windows host's
        # installed-package inventory, so falling back to them would test a Windows host against apt names and
        # silently conclude that nothing is installed.
        fam = fams.get(family) if family == "windows" else (
            fams.get(family) or fams.get("debian") or fams.get("ubuntu")
            or (next(iter(fams.values()), {}) if fams else {}))
        if isinstance(fam, dict) and any(name in inv for name in fam.get("packages", [])):
            out.append((role, entry, fam))
    return out


# ─────────────────────────────────────────────────────────── derivation (populate host_capabilities)


def derive_rows(facts: dict, catalog: dict, settings: Settings) -> list[dict]:
    """Pure: the host_capabilities rows a host's installed roles imply. One row per provides/requires
    entry of each role's capabilities.json."""
    rows: list[dict] = []
    for role, entry, fam in installed_roles(facts, catalog):
        template = entry.get("template") or role
        caps = load_template_capabilities(settings, template)
        if not caps:
            continue
        config_path = fam.get("config_path") or ""
        peer = caps.get("peer_injection", []) or []
        for prov in caps.get("provides", []) or []:
            if not isinstance(prov, dict) or not prov.get("capability"):
                continue
            # Carry any peer_injection for THIS capability onto the provide row, so the matcher can wire
            # the consumer's address into the provider's client-list field (e.g. NFS exports) from one row.
            detail = dict(prov)
            pis = [p for p in peer if isinstance(p, dict) and p.get("capability") == prov["capability"]]
            if pis:
                detail["peer_injection"] = pis
            rows.append({
                "kind": "provide", "capability": prov["capability"], "backend": prov.get("backend"),
                "template": template, "port": prov.get("default_port"), "config_path": config_path,
                "detail": detail,
            })
        for req in caps.get("requires", []) or []:
            if not isinstance(req, dict) or not req.get("capability"):
                continue
            rows.append({
                "kind": "require", "capability": req["capability"], "backend": None,
                "template": template, "port": None, "config_path": config_path, "detail": req,
            })
    return rows


async def reconcile_host_capabilities(session: AsyncSession, agent: Agent, rows: list[dict]) -> dict:
    """Replace the host's 'derived' rows with `rows`, leaving 'explicit' rows untouched (the HostLabel
    reconcile pattern). Caller owns the transaction (flush, not commit)."""
    existing = {
        (r.kind, r.capability, r.template): r
        for r in (await session.scalars(
            select(HostCapability).where(
                HostCapability.agent_id == agent.id, HostCapability.source == "derived")
        )).all()
    }
    now = datetime.now(timezone.utc)
    counts = {"new": 0, "changed": 0, "unchanged": 0, "vanished": 0}
    for row in rows:
        key = (row["kind"], row["capability"], row["template"])
        cur = existing.pop(key, None)
        if cur is None:
            counts["new"] += 1
            session.add(HostCapability(
                tenant_id=agent.tenant_id, agent_id=agent.id, source="derived", updated_at=now, **row))
        else:
            changed = (cur.backend != row["backend"] or cur.port != row["port"]
                       or cur.config_path != row["config_path"] or cur.detail != row["detail"])
            if changed:
                counts["changed"] += 1
                cur.backend, cur.port, cur.config_path, cur.detail = (
                    row["backend"], row["port"], row["config_path"], row["detail"])
            else:
                counts["unchanged"] += 1
            cur.updated_at = now
    for stale in existing.values():   # a role no longer installed → its derived rows vanish
        counts["vanished"] += 1
        await session.delete(stale)
    await session.flush()
    return counts


async def derive_agent(session: AsyncSession, agent: Agent, settings: Settings, catalog: dict | None = None) -> dict:
    catalog = catalog if catalog is not None else load_catalog(settings)
    rows = derive_rows(agent.facts or {}, catalog, settings)
    return await reconcile_host_capabilities(session, agent, rows)


async def derive_all(session: AsyncSession, settings: Settings) -> dict:
    catalog = load_catalog(settings)
    totals = {"agents": 0, "new": 0, "changed": 0, "unchanged": 0, "vanished": 0}
    for agent in (await session.scalars(select(Agent))).all():
        counts = await derive_agent(session, agent, settings, catalog)
        totals["agents"] += 1
        for k in ("new", "changed", "unchanged", "vanished"):
            totals[k] += counts[k]
    await session.commit()
    return totals


async def capabilities_loop(session_factory: async_sessionmaker, settings: Settings, stop_event) -> None:
    import asyncio
    if not settings.capabilities_enabled:
        return
    interval = max(60, settings.capabilities_interval_seconds)
    while not stop_event.is_set():
        try:
            async with session_factory() as session:
                totals = await derive_all(session, settings)
            logger.info("capabilities derive: %s", totals)
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 — one bad cycle must not kill the loop
            logger.exception("capabilities derive failed")
        try:
            await asyncio.wait_for(stop_event.wait(), timeout=interval)
        except asyncio.TimeoutError:
            pass


# ─────────────────────────────────────────────────────────── matcher (read host_capabilities)


def expand_backends(settings: Settings, backends: list[str]) -> set[str]:
    """A consumer that accepts backend X also accepts X's wire-compatible aliases (mysql<->mariadb,
    redis->valkey/keydb) — expand before intersecting with what a provider offers."""
    aliases = {k: v for k, v in (load_vocabulary(settings).get("backend_aliases") or {}).items()
               if not k.startswith("_")}
    out: set[str] = set()
    for b in backends or []:
        if not b:
            continue
        out.add(b)
        out.update(aliases.get(b, []))
    return out


def _agent_address(agent: Agent) -> str | None:
    """Best connection address for a provider host: primary IP/hostname from facts, else name."""
    facts = agent.facts or {}
    for key in ("primary_ip", "ip", "fqdn", "hostname"):
        v = facts.get(key)
        if isinstance(v, str) and v:
            return v
    return getattr(agent, "hostname", None) or getattr(agent, "name", None)


async def open_requirements(session: AsyncSession, agent_id: UUID) -> list[HostCapability]:
    """The host's 'require' rows — what this server needs from others."""
    return list(await session.scalars(
        select(HostCapability).where(HostCapability.agent_id == agent_id, HostCapability.kind == "require")
    ))


async def find_providers(
    session: AsyncSession, settings: Settings, capability: str, backends: list[str],
    tenant_id: UUID | None = None, exclude_agent: UUID | None = None,
) -> list[dict]:
    """Hosts in the inventory that PROVIDE `capability` with a backend the consumer accepts. Backend-empty
    means 'any backend of this capability'."""
    accepted = expand_backends(settings, backends)
    q = select(HostCapability, Agent).join(Agent, Agent.id == HostCapability.agent_id).where(
        HostCapability.kind == "provide", HostCapability.capability == capability)
    if tenant_id is not None:
        q = q.where(Agent.tenant_id == tenant_id)
    if exclude_agent is not None:
        q = q.where(HostCapability.agent_id != exclude_agent)
    out: list[dict] = []
    for cap, agent in (await session.execute(q)).all():
        if accepted and cap.backend and cap.backend not in accepted:
            continue
        out.append({
            "agent_id": str(agent.id), "hostname": getattr(agent, "hostname", None) or getattr(agent, "name", None),
            "address": _agent_address(agent), "capability": cap.capability, "backend": cap.backend,
            "port": cap.port, "template": cap.template, "config_path": cap.config_path, "detail": cap.detail,
        })
    return out


@lru_cache(maxsize=4)
def _provider_roles_index(templates_dir: str) -> dict[str, list[dict]]:
    """capability → [provider role candidates], built once by scanning every
    config_templates/<t>/capabilities.json directly (not via package_catalog,
    whose template linkage misses most enriched contracts). Each template dir is a
    role a NEW server could take on. Cached — the first call walks the tree once."""
    index: dict[str, list[dict]] = {}
    base = Path(templates_dir)
    if not base.is_dir():
        return index
    for capf in base.glob("*/capabilities.json"):
        try:
            caps = json.loads(capf.read_text())
        except (OSError, ValueError):
            continue
        if not isinstance(caps, dict):
            continue
        template = capf.parent.name
        for prov in caps.get("provides", []) or []:
            if not isinstance(prov, dict) or not prov.get("capability"):
                continue
            backend = prov.get("backend") or (prov.get("backends") or [None])[0]
            index.setdefault(prov["capability"], []).append({
                "role": template, "template": template, "label": template,
                "backend": backend, "default_port": prov.get("default_port")})
    return index


def roles_providing(settings: Settings, capability: str, backend: str | None = None) -> list[dict]:
    """Which ROLE a NEW server would need to provide `capability` (optionally a
    specific backend) — from the per-template capabilities.json contracts. Enriches
    the label from package_catalog when a matching entry exists."""
    accepted = expand_backends(settings, [backend]) if backend else None
    catalog = load_catalog(settings)
    labels = {r: (e.get("label") or r) for r, e in catalog.items()} if isinstance(catalog, dict) else {}
    out: list[dict] = []
    for cand in _provider_roles_index(settings.config_templates_dir).get(capability, []):
        if accepted and cand.get("backend") and cand["backend"] not in accepted:
            continue
        out.append({**cand, "label": labels.get(cand["role"], cand["label"])})
    return out


def propose_wiring(requirement_detail: dict, provider: dict, consumer_address: str | None = None) -> dict:
    """Given a consumer's `requires` entry and a chosen provider (a find_providers dict), compute the field
    values BOTH sides need:
      - consumer_values: the consumer's host/port fields set to the provider's address/port (and a real
        backend_field set to the provider's backend);
      - provider_values.peer_injection: for a provider that injects peers (e.g. NFS exports), the field to
        append `consumer_address` to, with the items_style so the caller formats the entry correctly.
    """
    addr = provider.get("address")
    port = provider.get("port")
    fields = requirement_detail.get("fields") or {}
    field_names = {v for v in fields.values() if v}
    consumer_values: dict = {}
    for role, schema_field in fields.items():
        if not schema_field:
            continue
        if role == "host" and addr is not None:
            consumer_values[schema_field] = addr
        elif role == "port" and port is not None:
            consumer_values[schema_field] = port
    # Set a backend selector ONLY if it's a distinct field (not aliased onto host) — else we'd overwrite
    # the host with a backend token (the roundcube backend_field=db_host imperfection).
    bf = requirement_detail.get("backend_field")
    if bf and provider.get("backend") and bf not in field_names:
        consumer_values[bf] = provider["backend"]

    provider_values: dict = {}
    for pi in (provider.get("detail") or {}).get("peer_injection") or []:
        if isinstance(pi, dict) and pi.get("field"):
            provider_values.setdefault("peer_injection", []).append({
                "field": pi["field"], "add_client": consumer_address, "items_style": pi.get("items_style")})
    return {"consumer_values": consumer_values, "provider_values": provider_values}
