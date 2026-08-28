"""Vault — a read-only inventory of where encrypted secrets live.

Secrets in Bossman are stored as `vault:v1:` handles (services/vault.Vault) inside
JSONB — chiefly scope variables (ScopeVars.vars, the GPO-resolved host_vars) and
config-policy values. This surfaces WHERE a secret is held (scope + key) so an
operator can audit them, WITHOUT ever returning or decrypting the plaintext.
"""
from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import require_admin
from bossman.config import Settings, get_settings
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


class EncryptBody(BaseModel):
    """A value to turn into a vault handle. Never stored here — the caller keeps
    the returned handle and puts THAT into whatever plan or policy needs it."""
    value: str
    generate: bool = False       # ignore `value` and mint a strong passphrase
    length: int = 24


@router.post("/api/v1/vault/encrypt")
async def encrypt_value(
    body: EncryptBody,
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_admin),
) -> dict:
    """Turn a plaintext into a `vault:v1:` handle (optionally generating a strong
    passphrase first), and return ONLY the handle.

    This exists so a UI never has to put a plaintext secret into an operation: it
    posts the passphrase once, keeps the handle, and the handle is what travels in
    the plan (see disk_ops' LUKS ops, where apply() is the only place that decrypts).
    The plaintext is not persisted anywhere by this endpoint. `generate=true` also
    returns the plaintext once, because the operator has to be able to write it
    down — a LUKS passphrase that nobody knows makes the data unrecoverable.
    """
    import secrets as _secrets

    if body.generate:
        length = max(12, min(int(body.length or 24), 128))
        plaintext = _secrets.token_urlsafe(length)[:length]
    else:
        plaintext = body.value or ""
        if not plaintext:
            raise HTTPException(422, "value must not be empty (or pass generate=true)")
    handle = Vault(settings.vault_key, settings.vault_key_path).encrypt(plaintext)
    out = {"handle": handle}
    if body.generate:
        out["generated"] = plaintext     # shown once so it can be stored safely
    return out
