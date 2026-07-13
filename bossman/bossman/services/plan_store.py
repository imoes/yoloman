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

from bossman.db.models import DEFAULT_TENANT_ID, PlanDocument
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
