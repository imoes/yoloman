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
from bossman.services.auth import Identity, grants_of, hash_password, new_api_token, new_bossman_user

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
    """Who am I, and what may I manage — the one route any authenticated caller may hit.

    Returns the caller's kind (`user` or `api_token`), name, role, whether they are an admin, and
    the access grants they actually hold. The UI gates its admin surfaces on this.

    **The grants are selected by the same predicate the enforcement uses** (`grant_filter`), which
    was not always true: this route matched an api_token's grants by NAME while the host ACL
    matched by the token's UID, so a token sharing a name with a granted one was told it had
    `scope: all` and then refused with 403 by every route that acts. A view that contradicts the
    enforcement is worse than no view, because the reader cannot tell which one is lying.

    An admin sees `is_admin: true` and may hold no grants at all — admin bypasses the grant check
    entirely, so an empty list here does not mean an admin can do nothing. That asymmetry is why
    `is_admin` is its own field rather than something a client infers from the grants.
    """
    grants = await grants_of(session, identity)
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
    """Every account in this server, with its role. Admin only, like everything here except `/me`."""
    users = (await session.scalars(select(BossmanUser).order_by(BossmanUser.username))).all()
    return {"users": [_user_out(u) for u in users]}


@router.post("/api/v1/users")
async def create_user(
    body: CreateUserRequest, session: AsyncSession = Depends(get_session), _admin=Depends(require_admin)
) -> dict[str, Any]:
    """Create an account. Two roles exist: `admin` and `operator` (422 for anything else).

        **The role is not the host ACL.** `admin` bypasses the per-host check entirely; `operator` may
        manage nothing until an access grant says otherwise. Creating an operator therefore creates
        someone who can log in and see, and change nothing — which is the intended starting point, not
        an oversight.
        """
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
    """Change a role or a password; omitted fields stay as they are.

        Note what a role change does immediately: promoting to `admin` grants management of every host
        at once, because admin bypasses the grant check rather than being given grants. There is no
        per-host trace of that promotion in the grant table — the audit trail is where it is recorded.
        """
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
    """Delete an account.

        **409 when it is your own** — an admin who deletes themselves could leave an installation with
        no administrator and no way back in. 404 when there is no such user.

        Their access grants are subject-referenced by username, so a new account created with the same
        name would inherit them. Delete the grants too unless that is what you want.
        """
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
    """Every API token, by name and creation time, with whether it has been revoked.

        **The secret is not here and cannot be recovered** — only its hash is stored. A revoked token
        stays in this list rather than disappearing: "this token existed and was revoked" is a
        different fact from "no such token", and an audit entry referring to it must stay explainable.
        """
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
    """Mint an API token. **The secret is returned exactly once, in this response.**

        Only its hash is stored, so there is no endpoint that can show it again — if it is lost, revoke
        the token and mint another.

        **Names are not unique**, and that matters more than it looks: a grant binds to the token's
        UID, not to its name, so two tokens called `ci` are two different subjects. Creating a
        duplicate name is allowed and makes the *grants* ambiguous to read, which is why
        `POST /api/v1/access-grants` refuses to bind by an ambiguous name (409).
        """
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
    """Revoke a token: it stops authenticating immediately and stays in the list, stamped.

        Not a delete. Its grants are left in place — revoking authentication and removing authorisation
        are two separate acts, and a grant whose token is revoked is inert but still visible, which is
        what lets someone answer "what was this token allowed to do".
        """
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
        #: WHICH token this grant is bound to. Exposed because it, not the name, decides
        #: authorisation for an api_token — an admin looking at two grants with the same
        #: subject_ref could otherwise not tell them apart, and one of them may be dead.
        "subject_token_id": str(g.subject_token_id) if g.subject_token_id else None,
        "scope": g.scope,
        "agent_id": str(g.agent_id) if g.agent_id else None,
        "host_group_id": str(g.host_group_id) if g.host_group_id else None,
        "permission": g.permission,
    }


@router.get("/api/v1/access-grants")
async def list_grants(session: AsyncSession = Depends(get_session), _admin=Depends(require_admin)) -> dict[str, Any]:
    """Every access grant in the server: who may manage what.

        A grant is `(subject, scope)` — the subject being a user (by username) or an api_token (by its
        UID), the scope being `all`, one `host`, or one `host_group`. Admin users hold no grants and can
        do everything, so this table is not the complete answer to "who can reach this host"; it is the
        complete answer for everyone who is not an admin.

        `subject_token_id` is shown because it, not `subject_ref`, decides authorisation for a token —
        two grants can carry the same name and belong to different tokens, one of them possibly dead.
        """
    rows = (await session.scalars(select(AccessGrant).order_by(AccessGrant.subject_ref))).all()
    return {"grants": [_grant_out(g) for g in rows]}


@router.post("/api/v1/access-grants")
async def create_grant(
    body: CreateGrantRequest, session: AsyncSession = Depends(get_session), _admin=Depends(require_admin)
) -> dict[str, Any]:
    """Grant management rights: `all`, one host, or one host group.

        422 when the scope's own target is missing (`host` needs `agent_id`, `host_group` needs
        `host_group_id`) — a grant that names a scope without its object would be silently unusable.

        **An api_token grant binds to the token's UID, and an ambiguous name is refused (409)** rather
        than resolved by guessing. It was name-bound once, and that measurably applied one grant to
        every token sharing the name (28 of them for a single name). An authorisation must not depend
        on which of several rows a query happened to return first.
        """
    if body.subject_kind not in _SUBJECT_KINDS:
        raise HTTPException(status_code=422, detail=f"subject_kind must be one of: {', '.join(_SUBJECT_KINDS)}")
    if body.scope not in _SCOPES:
        raise HTTPException(status_code=422, detail=f"scope must be one of: {', '.join(_SCOPES)}")
    if body.scope == "host" and not body.agent_id:
        raise HTTPException(status_code=422, detail="scope=host requires agent_id")
    if body.scope == "host_group" and not body.host_group_id:
        raise HTTPException(status_code=422, detail="scope=host_group requires host_group_id")
    # An api_token grant is bound to the token's UID, not to its name: names are not unique, so a
    # name-bound grant applied to every token sharing it (measured: 28). The name is resolved here
    # and the ambiguity is REFUSED rather than resolved by guessing — an authorisation must not
    # depend on which of several rows a query happened to return first.
    token_id = None
    if body.subject_kind == "api_token":
        matches = (
            await session.scalars(select(ApiToken.id).where(ApiToken.name == body.subject_ref))
        ).all()
        if not matches:
            raise HTTPException(status_code=422, detail=f"no API token named {body.subject_ref!r}")
        if len(matches) > 1:
            raise HTTPException(
                status_code=409,
                detail=(
                    f"{len(matches)} API tokens are named {body.subject_ref!r} — a grant binds to one "
                    "token, so the name is ambiguous; rename or revoke the duplicates first"
                ),
            )
        token_id = matches[0]
    g = AccessGrant(
        subject_kind=body.subject_kind,
        subject_ref=body.subject_ref,
        subject_token_id=token_id,
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
    """Revoke a grant. Takes effect on the next request — nothing is cached.

        404 when there is no such grant. If the subject also holds a wider grant (`scope: all`, or a
        group containing the host), removing this one changes nothing; `GET /api/v1/access-grants` is
        how you check that before assuming access is gone.
        """
    g = await session.get(AccessGrant, grant_id)
    if g is None:
        raise HTTPException(status_code=404, detail="no such grant")
    await session.delete(g)
    await session.commit()
