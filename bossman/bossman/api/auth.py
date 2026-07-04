"""POST /api/v1/auth/login — the human-operator half of Bossman's dual
auth model (see docs/plan.md's Bossman plan): exchanges a username and
password for a JWT. Also exposes get_current_identity, the FastAPI
dependency every protected REST route (Block B7) uses to require
authentication — it accepts either a human JWT or a machine API token
behind the identical Authorization: Bearer header, resolving via
services.auth.resolve_identity.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.config import Settings, get_settings
from bossman.db.session import get_session
from bossman.services.auth import AuthError, Identity, authenticate_user, create_access_token, resolve_identity

router = APIRouter()


class LoginRequest(BaseModel):
    username: str
    password: str


class LoginResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"


@router.post("/api/v1/auth/login", response_model=LoginResponse)
async def login(
    body: LoginRequest,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
) -> LoginResponse:
    try:
        user = await authenticate_user(session, body.username, body.password)
    except AuthError:
        raise HTTPException(status_code=401, detail="invalid username or password") from None
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
