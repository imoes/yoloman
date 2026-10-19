"""Provision a database credential for a host — create a DB + user on a provider host and store the credential for
the consumer host as a vault handle. Out-of-band and secret-safe: the admin login is used only for this call and
never persisted, the app password is stored for the consumer as a `vault:v1:` handle, never in plaintext. See
services/db_provision. (Rehomed out of the former blueprints API; the blueprint designer was removed.)
"""

from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import Identity, require_admin
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.models import DEFAULT_TENANT_ID, Agent, ScopeVars
from bossman.db.session import get_session
from bossman.services import db_provision
from bossman.services.vault import Vault

router = APIRouter()


class ProvisionIn(BaseModel):
    """Provision a database + user on a provider host and store the credential for
    the consumer. Admin creds are used only for this call and never persisted; the
    app password is stored for the consumer as a vault handle.

    password_mode picks where the app password comes from:
      generate — mint a strong random one (default);
      custom   — use `password` supplied here;
      existing — reuse an already-stored secret referenced by
                 existing_scope_type + the matching id + existing_key (its value
                 must be a vault handle; it is decrypted only to run the SQL, and
                 the SAME handle is stored for the consumer)."""
    provider_agent_id: UUID           # reachable host the DB runs on
    exec: str = "local"               # "local" | "docker"
    container: str | None = None      # docker exec target when exec=docker
    backend: str = "mysql"            # mysql | mariadb
    admin_user: str
    admin_password: str
    db_name: str
    db_user: str
    consumer_agent_id: UUID           # host whose host_vars receive the credential
    targets: dict = {}                # {name|user|password: consumer var key}
    password_mode: str = "generate"   # generate | custom | existing
    password: str = ""                # custom mode
    existing_scope_type: str | None = None   # existing mode: host | group | ou
    existing_agent_id: UUID | None = None
    existing_host_group_id: UUID | None = None
    existing_ou_id: UUID | None = None
    existing_key: str | None = None


@router.post("/api/v1/provision/database")
async def provision_credentials(
    body: ProvisionIn, session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings), client_factory=Depends(get_client_factory),
    _identity: Identity = Depends(require_admin),
) -> dict:
    """Out-of-band credential provisioning (secret-safe): create the DB+user on the
    provider via the agent `command` module, then store the password for the consumer
    as a vault handle in its host_vars. No plaintext is persisted and no agent module
    is required."""
    provider = await session.get(Agent, body.provider_agent_id)
    if provider is None:
        raise HTTPException(404, "no such provider host")
    if not provider.address:
        raise HTTPException(409, "provider host has no direct address — cannot reach it to provision")
    consumer = await session.get(Agent, body.consumer_agent_id)
    if consumer is None:
        raise HTTPException(404, "no such consumer host")

    vault = Vault(settings.vault_key, settings.vault_key_path)

    # Resolve the app password per mode. `existing_handle` is set only for the
    # "existing" mode so the consumer keeps the SAME secret reference.
    app_password: str | None = None
    existing_handle: str | None = None
    if body.password_mode == "custom":
        if not body.password:
            raise HTTPException(422, "custom password mode needs a `password`")
        app_password = body.password
    elif body.password_mode == "existing":
        if not (body.existing_scope_type and body.existing_key):
            raise HTTPException(422, "existing mode needs existing_scope_type + existing_key")
        ref = await session.scalar(select(ScopeVars).where(
            ScopeVars.tenant_id == DEFAULT_TENANT_ID,
            ScopeVars.scope_type == body.existing_scope_type,
            ScopeVars.agent_id == body.existing_agent_id,
            ScopeVars.host_group_id == body.existing_host_group_id,
            ScopeVars.ou_id == body.existing_ou_id))
        handle = (ref.vars if ref else {}).get(body.existing_key) if ref else None
        if not Vault.is_encrypted(handle):
            raise HTTPException(422, "referenced value is not an encrypted secret")
        try:
            app_password = vault.decrypt(handle)
        except Exception:  # noqa: BLE001
            raise HTTPException(422, "could not decrypt the referenced secret")
        existing_handle = handle
    # else: generate → app_password stays None (minted by the recipe)

    client = client_factory(provider, settings)
    res = await db_provision.provision_database(
        client, backend=body.backend, exec_mode=body.exec, container=body.container,
        admin_user=body.admin_user, admin_password=body.admin_password,
        db_name=body.db_name, db_user=body.db_user, app_password=app_password)
    if not res.get("ok"):
        raise HTTPException(502, res.get("error") or "provisioning failed")

    produced = res.get("produced_params") or {}
    pw_handle = existing_handle if existing_handle else vault.encrypt(produced.get("password", ""))
    row = await session.scalar(select(ScopeVars).where(
        ScopeVars.tenant_id == DEFAULT_TENANT_ID, ScopeVars.scope_type == "host",
        ScopeVars.agent_id == body.consumer_agent_id))
    merged = dict((row.vars if row else {}) or {})
    stored: list[str] = []
    if body.targets.get("name") and produced.get("name"):
        merged[body.targets["name"]] = produced["name"]; stored.append(body.targets["name"])
    if body.targets.get("user") and produced.get("user"):
        merged[body.targets["user"]] = produced["user"]; stored.append(body.targets["user"])
    if body.targets.get("password"):
        merged[body.targets["password"]] = pw_handle; stored.append(body.targets["password"])
    if row is None:
        row = ScopeVars(tenant_id=DEFAULT_TENANT_ID, scope_type="host",
                        agent_id=body.consumer_agent_id, vars=merged)
        session.add(row)
    else:
        row.vars = merged
    await session.commit()
    return {"ok": True, "provider": provider.name, "consumer": consumer.name,
            "database": produced.get("name"), "user": produced.get("user"),
            "password_mode": body.password_mode, "stored_keys": stored, "password": Vault.mask()}
