"""Vault — a read-only inventory of where encrypted secrets live.

Secrets in Bossman are stored as `vault:v1:` handles (services/vault.Vault) inside
JSONB — chiefly scope variables (ScopeVars.vars, the GPO-resolved host_vars) and
config-policy values. This surfaces WHERE a secret is held (scope + key) so an
operator can audit them, WITHOUT ever returning or decrypting the plaintext.
"""
from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import require_admin
from bossman.db.models import Agent, ConfigPolicy, HostGroup, OUNode, ScopeVars
from bossman.db.session import get_session
from bossman.services.vault import Vault

router = APIRouter()


def _is_secret(v: object) -> bool:
    return Vault.is_encrypted(v)


async def _scope_labels(session: AsyncSession) -> dict[tuple[str, UUID], str]:
    """(scope_type, id) → human label, so the inventory reads by name not UUID."""
    out: dict[tuple[str, UUID], str] = {}
    for a in (await session.scalars(select(Agent))).all():
        out[("host", a.id)] = a.name
    for g in (await session.scalars(select(HostGroup))).all():
        out[("group", g.id)] = g.name
    for o in (await session.scalars(select(OUNode))).all():
        out[("ou", o.id)] = getattr(o, "name", None) or str(o.id)
    return out


@router.get("/api/v1/vault/secrets")
async def list_secrets(
    session: AsyncSession = Depends(get_session),
    _identity=Depends(require_admin),
) -> dict:
    """Every encrypted secret reference held in the vault — scope variables and
    config-policy values whose stored value is a `vault:v1:` handle. Returns the
    location (scope/policy + key) and NEVER the plaintext."""
    labels = await _scope_labels(session)
    secrets: list[dict] = []

    for sv in (await session.scalars(select(ScopeVars))).all():
        sid = sv.agent_id or sv.host_group_id or sv.ou_id
        label = labels.get((sv.scope_type, sid)) if sid else None
        for key, value in (sv.vars or {}).items():
            if _is_secret(value):
                secrets.append({
                    "source": "scope-var", "scope_type": sv.scope_type,
                    "scope": label or (str(sid) if sid else "?"), "key": key,
                })

    for cp in (await session.scalars(select(ConfigPolicy))).all():
        for key, value in (cp.values or {}).items():
            if _is_secret(value):
                secrets.append({
                    "source": "config-policy", "scope_type": "policy",
                    "scope": getattr(cp, "path", None) or str(cp.id), "key": key,
                })

    secrets.sort(key=lambda s: (s["source"], s["scope"], s["key"]))
    by_source: dict[str, int] = {}
    for s in secrets:
        by_source[s["source"]] = by_source.get(s["source"], 0) + 1
    return {"total": len(secrets), "by_source": by_source, "secrets": secrets}
