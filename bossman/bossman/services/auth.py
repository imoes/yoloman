"""Authentication: password hashing + JWT issuance for human operators
(bossman_users), and hashed bearer tokens for machine/AI callers
(api_tokens) — the dual-auth split confirmed in docs/plan.md's Bossman
plan (mirrors the Go node agent's own PAM-for-humans/bearer-token-for-
machines split, one level up at the Bossman layer).

Framework-free (no FastAPI import), like services/enrollment.py,
services/poller.py, and services/plan_engine.py — the FastAPI-specific
dependency wiring (extracting the Authorization header, raising the right
HTTP status) lives in bossman/api/auth.py (Block B7).
"""

from __future__ import annotations

import hashlib
import secrets
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

import jwt
from passlib.context import CryptContext
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.config import Settings
from bossman.db.models import AccessGrant, ApiToken, BossmanUser, HostGroupMember

_pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

# Hashing a fixed dummy password when a username lookup misses keeps the
# authenticate_user() timing profile similar to a real wrong-password
# case, rather than returning instantly and letting a caller distinguish
# "no such user" from "wrong password" by response latency.
_DUMMY_HASH = _pwd_context.hash("bossman-timing-equalizer")


class AuthError(Exception):
    """Raised for any authentication failure — bad password, invalid/
    expired JWT, or an unknown/revoked API token. Deliberately one
    exception type for all three: callers (FastAPI dependencies) map it to
    401 without needing to distinguish the cause, the same way a wrong
    username and a wrong password should look identical to the caller."""


def hash_password(password: str) -> str:
    return _pwd_context.hash(password)


def verify_password(password: str, password_hash: str) -> bool:
    return _pwd_context.verify(password, password_hash)


def new_bossman_user(username: str, password: str, role: str = "operator") -> BossmanUser:
    return BossmanUser(username=username, password_hash=hash_password(password), role=role)


async def authenticate_user(session: AsyncSession, username: str, password: str) -> BossmanUser:
    user = await session.scalar(select(BossmanUser).where(BossmanUser.username == username))
    if user is None:
        verify_password(password, _DUMMY_HASH)  # burn equivalent time, see _DUMMY_HASH's comment
        raise AuthError("invalid username or password")
    if not verify_password(password, user.password_hash):
        raise AuthError("invalid username or password")
    return user


@dataclass
class TokenClaims:
    username: str
    role: str


def create_access_token(user: BossmanUser, settings: Settings) -> str:
    now = datetime.now(timezone.utc)
    payload = {
        "sub": user.username,
        "role": user.role,
        "iat": now,
        "exp": now + timedelta(minutes=settings.jwt_ttl_minutes),
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm=settings.jwt_algorithm)


def decode_access_token(token: str, settings: Settings) -> TokenClaims:
    try:
        payload = jwt.decode(token, settings.jwt_secret, algorithms=[settings.jwt_algorithm])
    except jwt.PyJWTError as exc:
        raise AuthError(f"invalid token: {exc}") from exc
    return TokenClaims(username=payload["sub"], role=payload["role"])


def generate_api_token() -> str:
    """A fresh, cryptographically random bearer token for a machine/AI
    caller — hex-encoded, mirroring the Go node agent's own
    newBearerToken() convention (cmd/agentic-mcpd/register.go)."""
    return secrets.token_hex(32)


def hash_api_token(token: str) -> str:
    """A fast, deterministic hash — deliberately not bcrypt. An API token
    already carries 256 bits of its own entropy, so (unlike a human
    password) there's no meaningful enumeration risk from a fast hash;
    and a fast, deterministic hash is what makes an O(1) "look up the row
    by token" query possible at all — bcrypt's per-hash random salt means
    you can only *verify* against a hash you already know which row it
    belongs to, not look one up by it."""
    return hashlib.sha256(token.encode()).hexdigest()


def new_api_token(name: str) -> tuple[ApiToken, str]:
    """Returns (row to persist, raw token to hand to the caller once) —
    the raw value is never retrievable again after this; only its hash is
    stored.

    The id is generated HERE rather than left to the column's server default, so a caller can
    reference the token (an AccessGrant's `subject_token_id`) without an early flush. The
    server-default version read back as None until flushed, and binding a grant to that None hit
    the new "an api_token grant needs a uid" constraint — the same trick api/templates.py already
    uses for the same reason.
    """
    raw = generate_api_token()
    return ApiToken(id=uuid.uuid4(), name=name, token_hash=hash_api_token(raw)), raw


async def authenticate_api_token(session: AsyncSession, token: str) -> ApiToken:
    row = await session.scalar(select(ApiToken).where(ApiToken.token_hash == hash_api_token(token)))
    if row is None or row.revoked_at is not None:
        raise AuthError("invalid or revoked API token")
    return row


async def revoke_api_token(session: AsyncSession, api_token: ApiToken) -> None:
    api_token.revoked_at = datetime.now(timezone.utc)


@dataclass
class Identity:
    """A resolved caller, whichever of the two auth mechanisms it came
    from — REST routes (Block B7) authorize against this, not against a
    BossmanUser/ApiToken row directly, the same way the Go node agent's
    own internal/authz.IdentityFromContext abstracts PAM vs. bearer-token
    identities behind one shape for its request handlers."""

    kind: str  # "user" | "api_token"
    name: str
    role: str | None = None  # only set for kind == "user"
    #: The api_token's UID. Authorization matches grants on THIS, not on the name: token names are
    #: not unique, so name matching let one grant authorise every token sharing a name (measured:
    #: 28 for "mon-caller"). Carried on the identity so the check needs no second lookup.
    token_id: object | None = None  # only set for kind == "api_token"


async def user_can_manage_agent(session: AsyncSession, identity: Identity, agent_id) -> bool:
    """Block M authorization: may this caller MANAGE this host?

    admin users bypass entirely. Every other user AND every api_token needs a
    grant: scope='all' (wildcard) → yes; scope='host' matching agent_id → yes;
    scope='host_group' where the host is a member → yes. Otherwise no."""
    if identity.kind == "user" and identity.role == "admin":
        return True
    # An api_token is matched by its UID, a user by its username. The name was the reference for
    # both until it was measured granting rights across tokens that merely shared a name; a
    # username is still the identity for a user, because there is no separate uid to point at.
    if identity.kind == "api_token":
        if identity.token_id is None:
            # No uid means this identity was built by something that predates the change — refused
            # rather than silently falling back to name matching, which is what is being removed.
            return False
        where = (AccessGrant.subject_kind == "api_token", AccessGrant.subject_token_id == identity.token_id)
    else:
        where = (AccessGrant.subject_kind == identity.kind, AccessGrant.subject_ref == identity.name)
    grants = (await session.scalars(select(AccessGrant).where(*where))).all()
    group_ids: list = []
    for g in grants:
        if g.scope == "all":
            return True
        if g.scope == "host" and g.agent_id is not None and str(g.agent_id) == str(agent_id):
            return True
        if g.scope == "host_group" and g.host_group_id is not None:
            group_ids.append(g.host_group_id)
    if group_ids:
        member = await session.scalar(
            select(HostGroupMember.id).where(
                HostGroupMember.agent_id == agent_id,
                HostGroupMember.host_group_id.in_(group_ids),
            )
        )
        if member is not None:
            return True
    return False


async def resolve_identity(session: AsyncSession, settings: Settings, bearer: str) -> Identity:
    """Resolves a raw Authorization: Bearer value to either a human user
    (JWT) or a machine API token — both are presented via the identical
    header, so a JWT decode is tried first (a JWT is a distinctly
    structured, signed string; a random hex API token will simply fail to
    decode as one) before falling back to an API token lookup."""
    try:
        claims = decode_access_token(bearer, settings)
        return Identity(kind="user", name=claims.username, role=claims.role)
    except AuthError:
        pass
    api_token = await authenticate_api_token(session, bearer)
    return Identity(kind="api_token", name=api_token.name, token_id=api_token.id)
