"""Block M — user / API-token / access-grant administration.

All management routes are admin-only (require_admin). GET /api/v1/me is the
one route any authenticated caller may hit: it returns their own identity +
grants so the UI can gate admin surfaces and show what a user may manage.

The host ACL itself (who may manage which host) is enforced elsewhere via
require_manage_agent (api/auth.py) reading the access_grants this API writes.
"""

from __future__ import annotations

from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity, require_admin
from bossman.db.models import AccessGrant, ApiToken, BossmanUser
from bossman.db.session import get_session
from bossman.services.auth import Identity, hash_password, new_api_token, new_bossman_user

router = APIRouter()

_ROLES = ("admin", "operator")
_SUBJECT_KINDS = ("user", "api_token")
_SCOPES = ("all", "host", "host_group")


# ---- self ------------------------------------------------------------------


@router.get("/api/v1/me")
async def whoami(
    session: AsyncSession = Depends(get_session),
    identity: Identity = Depends(get_current_identity),
) -> dict[str, Any]:
    grants = (
        await session.scalars(
            select(AccessGrant).where(
                AccessGrant.subject_kind == identity.kind, AccessGrant.subject_ref == identity.name
            )
        )
    ).all()
    return {
        "kind": identity.kind,
        "name": identity.name,
        "role": identity.role,
        "is_admin": identity.kind == "user" and identity.role == "admin",
        "grants": [_grant_out(g) for g in grants],
    }


# ---- users -----------------------------------------------------------------


class CreateUserRequest(BaseModel):
    username: str
    password: str
    role: str = "operator"


class UpdateUserRequest(BaseModel):
    role: str | None = None
    password: str | None = None


def _user_out(u: BossmanUser) -> dict[str, Any]:
    return {"id": str(u.id), "username": u.username, "role": u.role, "created_at": u.created_at.isoformat() if u.created_at else None}


@router.get("/api/v1/users")
async def list_users(session: AsyncSession = Depends(get_session), _admin=Depends(require_admin)) -> dict[str, Any]:
    users = (await session.scalars(select(BossmanUser).order_by(BossmanUser.username))).all()
    return {"users": [_user_out(u) for u in users]}


@router.post("/api/v1/users")
async def create_user(
    body: CreateUserRequest, session: AsyncSession = Depends(get_session), _admin=Depends(require_admin)
) -> dict[str, Any]:
    if body.role not in _ROLES:
        raise HTTPException(status_code=422, detail=f"role must be one of: {', '.join(_ROLES)}")
    if not body.username.strip() or not body.password:
        raise HTTPException(status_code=422, detail="username and password required")
    if await session.scalar(select(BossmanUser).where(BossmanUser.username == body.username)):
        raise HTTPException(status_code=409, detail=f"user {body.username!r} already exists")
    u = new_bossman_user(body.username, body.password, body.role)
    session.add(u)
    await session.flush()
    await session.commit()
    return _user_out(u)


@router.patch("/api/v1/users/{username}")
async def update_user(
    username: str, body: UpdateUserRequest, session: AsyncSession = Depends(get_session), _admin=Depends(require_admin)
) -> dict[str, Any]:
    u = await session.scalar(select(BossmanUser).where(BossmanUser.username == username))
    if u is None:
        raise HTTPException(status_code=404, detail=f"no such user {username!r}")
    if body.role is not None:
        if body.role not in _ROLES:
            raise HTTPException(status_code=422, detail=f"role must be one of: {', '.join(_ROLES)}")
        u.role = body.role
    if body.password:
        u.password_hash = hash_password(body.password)
    await session.commit()
    return _user_out(u)


@router.delete("/api/v1/users/{username}", status_code=204)
async def delete_user(username: str, session: AsyncSession = Depends(get_session), admin=Depends(require_admin)) -> None:
    u = await session.scalar(select(BossmanUser).where(BossmanUser.username == username))
    if u is None:
        raise HTTPException(status_code=404, detail=f"no such user {username!r}")
    if u.username == admin.name:
        raise HTTPException(status_code=409, detail="cannot delete your own account")
    await session.delete(u)
    await session.commit()


# ---- API tokens ------------------------------------------------------------


class CreateTokenRequest(BaseModel):
    name: str


@router.get("/api/v1/api-tokens")
async def list_tokens(session: AsyncSession = Depends(get_session), _admin=Depends(require_admin)) -> dict[str, Any]:
    rows = (await session.scalars(select(ApiToken).order_by(ApiToken.name))).all()
    return {
        "tokens": [
            {"id": str(t.id), "name": t.name, "created_at": t.created_at.isoformat() if t.created_at else None,
             "revoked": t.revoked_at is not None}
            for t in rows
        ]
    }


@router.post("/api/v1/api-tokens")
async def create_token(
    body: CreateTokenRequest, session: AsyncSession = Depends(get_session), _admin=Depends(require_admin)
) -> dict[str, Any]:
    if not body.name.strip():
        raise HTTPException(status_code=422, detail="name required")
    row, raw = new_api_token(body.name.strip())
    session.add(row)
    await session.flush()
    await session.commit()
    # The raw token is shown exactly once — only its hash is stored.
    return {"id": str(row.id), "name": row.name, "token": raw}


@router.delete("/api/v1/api-tokens/{token_id}", status_code=204)
async def revoke_token(token_id: UUID, session: AsyncSession = Depends(get_session), _admin=Depends(require_admin)) -> None:
    from datetime import datetime, timezone

    t = await session.get(ApiToken, token_id)
    if t is None:
        raise HTTPException(status_code=404, detail="no such token")
    t.revoked_at = datetime.now(timezone.utc)
    await session.commit()


# ---- access grants ---------------------------------------------------------


class CreateGrantRequest(BaseModel):
    subject_kind: str  # user | api_token
    subject_ref: str
    scope: str  # all | host | host_group
    agent_id: UUID | None = None
    host_group_id: UUID | None = None


def _grant_out(g: AccessGrant) -> dict[str, Any]:
    return {
        "id": str(g.id),
        "subject_kind": g.subject_kind,
        "subject_ref": g.subject_ref,
        "scope": g.scope,
        "agent_id": str(g.agent_id) if g.agent_id else None,
        "host_group_id": str(g.host_group_id) if g.host_group_id else None,
        "permission": g.permission,
    }


@router.get("/api/v1/access-grants")
async def list_grants(session: AsyncSession = Depends(get_session), _admin=Depends(require_admin)) -> dict[str, Any]:
    rows = (await session.scalars(select(AccessGrant).order_by(AccessGrant.subject_ref))).all()
    return {"grants": [_grant_out(g) for g in rows]}


@router.post("/api/v1/access-grants")
async def create_grant(
    body: CreateGrantRequest, session: AsyncSession = Depends(get_session), _admin=Depends(require_admin)
) -> dict[str, Any]:
    if body.subject_kind not in _SUBJECT_KINDS:
        raise HTTPException(status_code=422, detail=f"subject_kind must be one of: {', '.join(_SUBJECT_KINDS)}")
    if body.scope not in _SCOPES:
        raise HTTPException(status_code=422, detail=f"scope must be one of: {', '.join(_SCOPES)}")
    if body.scope == "host" and not body.agent_id:
        raise HTTPException(status_code=422, detail="scope=host requires agent_id")
    if body.scope == "host_group" and not body.host_group_id:
        raise HTTPException(status_code=422, detail="scope=host_group requires host_group_id")
    g = AccessGrant(
        subject_kind=body.subject_kind,
        subject_ref=body.subject_ref,
        scope=body.scope,
        agent_id=body.agent_id if body.scope == "host" else None,
        host_group_id=body.host_group_id if body.scope == "host_group" else None,
    )
    session.add(g)
    await session.flush()
    await session.commit()
    return _grant_out(g)


@router.delete("/api/v1/access-grants/{grant_id}", status_code=204)
async def delete_grant(grant_id: UUID, session: AsyncSession = Depends(get_session), _admin=Depends(require_admin)) -> None:
    g = await session.get(AccessGrant, grant_id)
    if g is None:
        raise HTTPException(status_code=404, detail="no such grant")
    await session.delete(g)
    await session.commit()
