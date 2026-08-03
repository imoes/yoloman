"""The canonical, prefix-keyed plan document store (docs/zielbestimmung.md
principle 4). One place that turns any accepted source format into the
canonical JSON plan body, versions it, and hands back a ready-to-run
plan_loader.Plan — so the engine, CLI, and API all read plans from ONE store
instead of the previous split between file-based plans_dir and the
orchestration_plans tables.

Canonical body = the (coerced) raw dict that plan_loader.build_plan_from_raw
consumes. NestedText/YAML/JSON produce it deterministically; the future
Chef/Puppet/Salt parsers (docs/zielbestimmung.md roadmap) will feed the same
store via canonical_from_source with their own prefix.
"""

from __future__ import annotations

import hashlib
import json
import uuid
from pathlib import Path
from typing import Any

import nestedtext
import yaml
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import DEFAULT_TENANT_ID, PlanDocument, PlanPlacement
from bossman.services.nt_plan_loader import _coerce_plan_raw
from bossman.services.plan_loader import Plan, PlanError, build_plan_from_raw

# Origin systems a plan can come from (the `prefix`). NestedText/YAML/JSON are
# all "ansible" (the Ansible-shaped native plan); the others are foreign DSLs
# imported by deterministic parsers (roadmap).
VALID_PREFIXES = ("ansible", "salt", "puppet", "chef")
# Source syntaxes convertible today. Foreign DSLs land here as parsers arrive
# (salt done; puppet/chef on the roadmap).
SUPPORTED_FORMATS = ("nestedtext", "yaml", "json", "salt", "chef", "puppet")


_ANSIBLE_BUILTIN_PREFIX = "ansible.builtin."


def _strip_ansible_builtin(raw: Any) -> None:
    """Rewrite step module keys of the form `ansible.builtin.<mod>` to the bare
    native name (`<mod>`), in place, wherever they appear (flat `steps` or
    per-chunk `steps`). yolo-man is not Ansible: the canonical body must never
    persist the `ansible.builtin.` prefix (the loader would strip it at run
    time anyway, but it must not leak into the library/editor). Collection
    FQCNs like `community.crypto.openssl_privatekey` are real translated
    modules and are left untouched."""
    if not isinstance(raw, dict):
        return
    for chunk in raw.get("chunks", []) if isinstance(raw.get("chunks"), list) else []:
        _strip_ansible_builtin(chunk)
    steps = list(raw.get("steps") or []) if isinstance(raw.get("steps"), list) else []
    handler = raw.get("final_handler")
    if isinstance(handler, dict):
        steps.append(handler)
    for step in steps:
        if not isinstance(step, dict):
            continue
        for key in [k for k in step if isinstance(k, str) and k.startswith(_ANSIBLE_BUILTIN_PREFIX)]:
            step[key[len(_ANSIBLE_BUILTIN_PREFIX):]] = step.pop(key)


def canonical_from_source(source_format: str, source_text: str, *, name: str | None = None) -> dict[str, Any]:
    """Convert a plan's source text (in `source_format`) into the canonical
    raw dict, validated by building it into a Plan. Raises PlanError on any
    malformed input or schema violation. `name` is required for formats whose
    source carries no plan name (salt/puppet/chef); NestedText/YAML/JSON take
    the name from the source itself."""
    fmt = source_format.lower()
    if fmt in ("nt", "nestedtext"):
        try:
            raw = nestedtext.loads(source_text, top="dict")
        except nestedtext.NestedTextError as exc:
            raise PlanError(f"invalid NestedText: {exc}") from exc
        raw = _coerce_plan_raw(raw if isinstance(raw, dict) else {})
    elif fmt in ("yaml", "yml"):
        try:
            raw = yaml.safe_load(source_text)
        except yaml.YAMLError as exc:
            raise PlanError(f"invalid YAML: {exc}") from exc
        if isinstance(raw, list):
            # A bare LIST is an Ansible task file (roles/*/tasks/main.yml) or a playbook — the single most
            # common real-world import, and it is not a plan mapping, so it used to be rejected outright
            # ("plan must be a mapping"). A plan STEP is already Ansible-task-shaped (module-as-key, see
            # plan_loader), so the list simply becomes the step list — no translation needed.
            raw = {"name": name or "tasks", "steps": raw}
    elif fmt == "json":
        try:
            raw = json.loads(source_text)
        except json.JSONDecodeError as exc:
            raise PlanError(f"invalid JSON: {exc}") from exc
    elif fmt == "salt":
        # Imported here (not at module top) so the core store has no hard
        # dependency on any single foreign parser.
        from bossman.services.salt_parser import parse_salt_sls

        raw = parse_salt_sls(source_text, name or "salt_state")
    elif fmt == "chef":
        from bossman.services.chef_parser import parse_chef_recipe

        raw = parse_chef_recipe(source_text, name or "chef_recipe")
    elif fmt == "puppet":
        from bossman.services.puppet_parser import parse_puppet_manifest

        raw = parse_puppet_manifest(source_text, name or "puppet_manifest")
    else:
        raise PlanError(f"unsupported source_format {source_format!r} (want one of {SUPPORTED_FORMATS})")

    if not isinstance(raw, dict):
        raise PlanError("plan must be a mapping")
    # Normalize away the legacy `ansible.builtin.` module prefix before it can
    # persist into the canonical body (yolo-man is not Ansible).
    _strip_ansible_builtin(raw)
    # Validate + normalize by building; the returned Plan is discarded here,
    # the raw dict is what we persist as the canonical body.
    build_plan_from_raw(raw, Path(str(raw.get("name", "plan"))))
    return raw


def _tenant_uuid(tenant_id: str | uuid.UUID) -> uuid.UUID:
    return tenant_id if isinstance(tenant_id, uuid.UUID) else uuid.UUID(str(tenant_id))


async def _latest(session: AsyncSession, tenant: uuid.UUID, prefix: str, name: str) -> PlanDocument | None:
    return await session.scalar(
        select(PlanDocument)
        .where(PlanDocument.tenant_id == tenant, PlanDocument.prefix == prefix, PlanDocument.name == name)
        .order_by(PlanDocument.version.desc())
        .limit(1)
    )


async def store_plan(
    session: AsyncSession,
    prefix: str,
    name: str,
    source_format: str,
    source_text: str,
    *,
    tenant_id: str | uuid.UUID = DEFAULT_TENANT_ID,
    created_by: str | None = None,
) -> PlanDocument:
    """Convert + validate + persist a plan as a new immutable version.
    Idempotent: if the latest stored version already has the same
    content_hash, it is returned unchanged (no new version). The caller
    commits."""
    if prefix not in VALID_PREFIXES:
        raise PlanError(f"invalid prefix {prefix!r} (want one of {VALID_PREFIXES})")
    if not name:
        raise PlanError("name must not be empty")

    body = canonical_from_source(source_format, source_text, name=name)
    plan = build_plan_from_raw(body, Path(name))
    content_hash = plan.version()
    source_hash = hashlib.sha256(source_text.encode()).hexdigest()
    tenant = _tenant_uuid(tenant_id)

    existing = await _latest(session, tenant, prefix, name)
    if existing is not None and existing.content_hash == content_hash:
        return existing  # unchanged — no-op re-store

    doc = PlanDocument(
        tenant_id=tenant,
        prefix=prefix,
        name=name,
        version=(existing.version + 1) if existing is not None else 1,
        source_format=source_format.lower(),
        source_text=source_text,
        body=body,
        source_hash=source_hash,
        content_hash=content_hash,
        created_by=created_by,
    )
    session.add(doc)
    await session.flush()
    return doc


async def delete_plan(
    session: AsyncSession,
    prefix: str,
    name: str,
    *,
    tenant_id: str | uuid.UUID = DEFAULT_TENANT_ID,
) -> int:
    """Delete every stored version of a plan (and its folder placement).
    Returns the number of versions removed (0 if it did not exist). The caller
    commits. Plans are otherwise immutable/versioned; this is the one explicit
    removal path (a user deleting a plan from the library)."""
    if prefix not in VALID_PREFIXES:
        raise PlanError(f"invalid prefix {prefix!r} (want one of {VALID_PREFIXES})")
    tenant = _tenant_uuid(tenant_id)
    docs = (
        await session.scalars(
            select(PlanDocument).where(
                PlanDocument.tenant_id == tenant, PlanDocument.prefix == prefix, PlanDocument.name == name
            )
        )
    ).all()
    for doc in docs:
        await session.delete(doc)
    placement = await session.scalar(
        select(PlanPlacement).where(
            PlanPlacement.tenant_id == tenant, PlanPlacement.prefix == prefix, PlanPlacement.name == name
        )
    )
    if placement is not None:
        await session.delete(placement)
    return len(docs)


async def load_plan(
    session: AsyncSession,
    prefix: str,
    name: str,
    version: int | None = None,
    *,
    tenant_id: str | uuid.UUID = DEFAULT_TENANT_ID,
) -> Plan:
    """Rebuild a ready-to-run plan_loader.Plan from the stored canonical body
    (newest version unless `version` is given). No format re-parse."""
    tenant = _tenant_uuid(tenant_id)
    q = select(PlanDocument).where(
        PlanDocument.tenant_id == tenant, PlanDocument.prefix == prefix, PlanDocument.name == name
    )
    q = q.where(PlanDocument.version == version) if version is not None else q.order_by(PlanDocument.version.desc())
    row = await session.scalar(q.limit(1))
    if row is None:
        raise PlanError(f"no stored plan {prefix}/{name}" + (f"@v{version}" if version is not None else ""))
    return build_plan_from_raw(row.body, Path(name))


# File extension → source_format, for importing a plans_dir into the store.
_FORMAT_BY_EXT = {".yaml": "yaml", ".yml": "yaml", ".nt": "nestedtext", ".json": "json"}


async def import_plans_dir(
    session: AsyncSession,
    plans_dir: str,
    *,
    prefix: str = "ansible",
    tenant_id: str | uuid.UUID = DEFAULT_TENANT_ID,
) -> tuple[int, int]:
    """Import every plan file under plans_dir into the store (idempotent —
    store_plan dedups on content_hash). The file-based plans_dir becomes an
    import source; the store is the canonical home (docs/zielbestimmung.md
    #5). Returns (stored, failed). Caller commits."""
    d = Path(plans_dir)
    if not d.is_dir():
        return (0, 0)
    stored = failed = 0
    for p in sorted(d.iterdir()):
        if not p.is_file():
            continue
        fmt = _FORMAT_BY_EXT.get(p.suffix.lower())
        if fmt is None:
            continue
        try:
            await store_plan(session, prefix, p.stem, fmt, p.read_text(encoding="utf-8"), tenant_id=tenant_id)
            stored += 1
        except PlanError:
            failed += 1
    return (stored, failed)


async def list_plans(
    session: AsyncSession,
    prefix: str | None = None,
    *,
    tenant_id: str | uuid.UUID = DEFAULT_TENANT_ID,
) -> list[dict[str, Any]]:
    """Latest version of every stored plan (optionally filtered by prefix),
    newest-first — the listing for the catalog/API."""
    tenant = _tenant_uuid(tenant_id)
    q = select(PlanDocument).where(PlanDocument.tenant_id == tenant)
    if prefix is not None:
        q = q.where(PlanDocument.prefix == prefix)
    rows = (await session.scalars(q.order_by(PlanDocument.version.desc()))).all()
    latest: dict[tuple[str, str], dict[str, Any]] = {}
    for r in rows:
        key = (r.prefix, r.name)
        if key in latest:
            continue  # rows are version-desc, so the first seen is the latest
        latest[key] = {
            "prefix": r.prefix,
            "name": r.name,
            "version": r.version,
            "source_format": r.source_format,
            "content_hash": r.content_hash,
            "created_at": r.created_at.isoformat() if r.created_at else None,
        }
    return list(latest.values())


# --- bulk / directory import -----------------------------------------------------------------------

# Which orchestration DSL a file belongs to. Detection is POSITIVE — it names the directories where each
# framework keeps executable code — because real checkouts proved a negative (skip-list) approach unusable:
# geerlingguy/ansible-role-nginx, saltstack-formulas/apache-formula, puppetlabs-apache and sous-chefs/nginx
# between them contain kitchen.yml / pdk.yaml / hiera.yaml (tool config that is not a playbook),
# lib/puppet/functions/*.rb (PUPPET ruby, which an extension rule reads as Chef), test/**/\*_spec.rb (InSpec)
# and test/salt/pillar/*.sls (data, not states). Every one of those would have imported as a bogus plan.
#
# NOTE the sibling map below: _FORMAT_BY_EXT covers the NATIVE authoring formats (yaml/nt/json) for the
# file-based plans_dir import. This is for FOREIGN orchestration sources in a directory import, so it also
# carries the origin prefix.
#
# (dir, extension) -> (prefix, source_format). `dir` must appear as a path component.
_PLAN_RULES: tuple[tuple[str, str, str, str], ...] = (
    # Ansible: task files and playbooks — NOT vars/defaults/meta/templates, and not repo tooling.
    ("tasks", ".yml", "ansible", "yaml"),
    ("tasks", ".yaml", "ansible", "yaml"),
    ("handlers", ".yml", "ansible", "yaml"),
    ("handlers", ".yaml", "ansible", "yaml"),
    ("playbooks", ".yml", "ansible", "yaml"),
    ("playbooks", ".yaml", "ansible", "yaml"),
    # Salt: states live at the formula root or in a state dir; pillars are DATA, tests are fixtures.
    ("", ".sls", "salt", "salt"),
    # Puppet: classes/defines in manifests/. types/ holds data types, lib/ holds ruby — neither is a manifest.
    ("manifests", ".pp", "puppet", "puppet"),
    # Chef: recipes and custom resources. lib/, spec/, test/ are not the cookbook's code.
    ("recipes", ".rb", "chef", "chef"),
    ("resources", ".rb", "chef", "chef"),
)

# Directory components that disqualify a file whatever else matches: fixtures, tests and vendored copies.
_NEVER = ("test", "tests", "spec", "molecule", "pillar", "vendor", "node_modules", ".git", "fixtures")


def detect_plan_format(path: str) -> tuple[str, str] | None:
    """(prefix, source_format) for a file in a bulk import, or None to skip it.

    Pure, so the rules are testable against a real checkout without a database — and they were: the four
    upstream samples above are what shaped them.
    """
    low = path.replace("\\", "/").lower().lstrip("./")
    parts = low.split("/")
    base = parts[-1]
    if base.startswith("."):
        return None
    if any(p in _NEVER for p in parts[:-1]):
        return None
    for want_dir, ext, prefix, fmt in _PLAN_RULES:
        if not base.endswith(ext):
            continue
        if want_dir == "" or want_dir in parts[:-1]:
            return (prefix, fmt)
    return None


def plan_name_from_path(path: str) -> str:
    """A plan name from a file path, unique BY CONSTRUCTION: the whole relative path minus the extension,
    joined with dashes.

    The clever version — drop the conventional container dir and keep the stem — collides, and a collision
    here silently OVERWRITES a plan (store_plan keys on name). The real apache-formula contains both
    `apache/clean.sls` and `apache/config/certificates/clean.sls`; an Ansible role has both `tasks/main.yml`
    and `handlers/main.yml`. Longer names beat losing a plan.
    """
    clean = path.replace("\\", "/").strip("/").lstrip("./")
    parts = [p for p in clean.split("/") if p not in (".", "")]
    if not parts:
        return "plan"
    parts[-1] = parts[-1].rsplit(".", 1)[0] or parts[-1]
    joined = "-".join(parts)
    safe = "".join(c if (c.isalnum() or c in "-_.") else "-" for c in joined).strip("-")
    return safe or "plan"
