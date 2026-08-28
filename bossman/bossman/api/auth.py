"""POST /api/v1/auth/login and the first-run setup — the human-operator half of Bossman's dual
auth model (see docs/plan.md's Bossman plan): exchanges a username and
password for a JWT. Also exposes get_current_identity, the FastAPI
dependency every protected REST route (Block B7) uses to require
authentication — it accepts either a human JWT or a machine API token
behind the identical Authorization: Bearer header, resolving via
services.auth.resolve_identity.
"""

from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.config import Settings, get_settings
from bossman.db.models import BossmanUser
from bossman.db.session import get_session
from bossman.services.audit import record_audit
from bossman.services.auth import (
    AuthError,
    Identity,
    authenticate_user,
    create_access_token,
    hash_password,
    resolve_identity,
    user_can_manage_agent,
)

router = APIRouter()


class LoginRequest(BaseModel):
    username: str
    password: str


class LoginResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"


class SetupRequest(BaseModel):
    username: str
    password: str


class SetupState(BaseModel):
    """Whether this installation still has to be set up. `needs_setup` is true only while the user table is
    EMPTY — not "no admin", not "the seeded default is unchanged": exactly zero accounts."""
    needs_setup: bool


@router.get("/api/v1/auth/setup", response_model=SetupState)
async def setup_state(session: AsyncSession = Depends(get_session)) -> SetupState:
    """Unauthenticated on purpose — it is asked BEFORE anyone can log in, and its only answer is a boolean
    about whether an account exists. It leaks nothing that a failed login would not.
    """
    return SetupState(needs_setup=await _no_users_yet(session))


@router.post("/api/v1/auth/setup", response_model=LoginResponse)
async def setup(
    body: SetupRequest,
    request: Request,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
) -> LoginResponse:
    """Create the FIRST operator account, and only the first.

    WHY THIS EXISTS. The native install told the operator to run `bossman-create-admin <user> <password>` on
    the console — a password in shell history, and a step that cannot be done at all by someone who has the
    web console open and no shell on that host.

    WHY IT CANNOT BE ABUSED, and this is the whole design: the route refuses the moment ANY account exists.
    An installation that has been set up returns 409 forever, so this is not a signup endpoint that someone
    forgot to protect — it is a one-shot that closes behind itself.
    The check and the insert share one transaction, so two browsers racing the form cannot both win.

    It returns a token, so the operator is logged in and does not have to type the password again — and the
    audit trail records who was created, from where.
    """
    if not await _no_users_yet(session):
        # 409, not 403: the request is not forbidden, it is no longer applicable. An operator who sees this
        # has an account somewhere and needs the login form, which is what the UI does with it.
        raise HTTPException(status_code=409, detail="this installation already has an account — sign in instead")
    username = (body.username or "").strip()
    if not username or not body.password:
        raise HTTPException(status_code=422, detail="a username and a password are required")
    # The one policy applied here. Nothing else is judged — a length floor is checkable and honest; a
    # complexity rule would only teach people to write Passw0rd!.
    if len(body.password) < 12:
        raise HTTPException(status_code=422, detail="the password must be at least 12 characters")

    user = BossmanUser(username=username, password_hash=hash_password(body.password), role="admin")
    session.add(user)
    try:
        await session.commit()
    except IntegrityError as exc:
        # The race the transaction above is meant to lose safely: two setup forms submitted at once.
        await session.rollback()
        raise HTTPException(status_code=409, detail="this installation already has an account") from exc
    await record_audit(session, actor=username, actor_kind="user", category="auth", action="setup",
                       method="POST", path="/api/v1/auth/setup", target=username,
                       source_ip=request.client.host if request.client else None,
                       detail={"role": "admin", "first_account": True})
    return LoginResponse(access_token=create_access_token(user, settings))


async def _no_users_yet(session: AsyncSession) -> bool:
    """True while the user table is empty. One query, and deliberately not "is there an admin": a non-admin
    account still means somebody has been here, and offering to create an admin then would be a way in."""
    return (await session.scalar(select(func.count()).select_from(BossmanUser))) == 0


@router.post("/api/v1/auth/login", response_model=LoginResponse)
async def login(
    body: LoginRequest,
    request: Request,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
) -> LoginResponse:
    """Log in and get the bearer token everything else needs.

    Send `{"username", "password"}`; the response carries `access_token`, which goes
    into `Authorization: Bearer <token>` on every other call in this API. Only this
    endpoint and `/healthz` work without one.

    A failed attempt is recorded in the audit trail with the source IP (action
    `auth.login_failed`) — a login that nobody can see failing is a login nobody can
    see being attacked.
    """
    ip = request.client.host if request.client else None
    try:
        user = await authenticate_user(session, body.username, body.password)
    except AuthError:
        if settings.audit_enabled:
            await record_audit(
                session, actor=body.username, action="auth.login_failed", category="auth",
                actor_kind="user", method="POST", path="/api/v1/auth/login",
                status="failed", status_code=401, source_ip=ip,
            )
        raise HTTPException(status_code=401, detail="invalid username or password") from None
    if settings.audit_enabled:
        await record_audit(
            session, actor=user.username, action="auth.login", category="auth",
            actor_kind="user", method="POST", path="/api/v1/auth/login",
            status="ok", status_code=200, source_ip=ip,
        )
    return LoginResponse(access_token=create_access_token(user, settings))


async def get_current_identity(
    request: Request,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
) -> Identity:
    auth_header = request.headers.get("authorization", "")
    if not auth_header.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    bearer = auth_header[len("bearer ") :]
    try:
        return await resolve_identity(session, settings, bearer)
    except AuthError:
        raise HTTPException(status_code=401, detail="invalid credentials") from None


async def require_admin(identity: Identity = Depends(get_current_identity)) -> Identity:
    """Gate a route to admin users only (Block M). API tokens and operators
    get 403 — user/token/grant administration is admin-only."""
    if not (identity.kind == "user" and identity.role == "admin"):
        raise HTTPException(status_code=403, detail="admin role required")
    return identity


async def require_manage_agent(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    identity: Identity = Depends(get_current_identity),
) -> Identity:
    """Block M host ACL: authorize the caller to MANAGE the {agent_id} in the
    path. admin bypasses; everyone else needs a matching AccessGrant. 403 on
    denial. Used on per-host mutating/management routes."""
    if not await user_can_manage_agent(session, identity, agent_id):
        raise HTTPException(status_code=403, detail="not authorized to manage this host")
    return identity
