"""Tests for bossman.services.auth. Password hashing / JWT encode-decode
are pure and need no DB; user/API-token lookups use the real database via
tests/conftest.py's db_session fixture (skips if unreachable) — never
mocked, consistent with every other services/ test in this project.
"""

import uuid
from tests.naming import owned_name

import jwt
import pytest

from bossman.config import Settings
from bossman.db.models import BossmanUser
from bossman.services.auth import (
    AuthError,
    authenticate_api_token,
    authenticate_user,
    create_access_token,
    decode_access_token,
    generate_api_token,
    hash_api_token,
    hash_password,
    new_api_token,
    new_bossman_user,
    resolve_identity,
    revoke_api_token,
    verify_password,
)


def _settings(**overrides):
    kwargs = {
        "database_url": "postgresql+asyncpg://unused/unused",
        "jwt_secret": "test-secret-at-least-32-bytes-long-for-hs256",
        "jwt_algorithm": "HS256",
        "jwt_ttl_minutes": 30,
    }
    kwargs.update(overrides)
    return Settings(**kwargs)


def test_hash_password_and_verify_roundtrip():
    h = hash_password("s3cret!")
    assert h != "s3cret!"
    assert verify_password("s3cret!", h)


def test_verify_password_wrong_password_fails():
    h = hash_password("s3cret!")
    assert not verify_password("wrong", h)


def test_create_and_decode_access_token_roundtrip():
    user = BossmanUser(username="alice", password_hash="x", role="admin")
    settings = _settings()

    token = create_access_token(user, settings)
    claims = decode_access_token(token, settings)

    assert claims.username == "alice"
    assert claims.role == "admin"


def test_decode_access_token_wrong_secret_fails():
    user = BossmanUser(username="alice", password_hash="x", role="admin")
    token = create_access_token(user, _settings(jwt_secret="a" * 32))

    with pytest.raises(AuthError):
        decode_access_token(token, _settings(jwt_secret="b" * 32))


def test_decode_access_token_expired_fails():
    settings = _settings()
    expired = jwt.encode(
        {"sub": "alice", "role": "admin", "exp": 1},  # unix epoch + 1 second: always in the past
        settings.jwt_secret,
        algorithm=settings.jwt_algorithm,
    )

    with pytest.raises(AuthError, match="invalid token"):
        decode_access_token(expired, settings)


def test_generate_api_token_is_random_hex():
    a, b = generate_api_token(), generate_api_token()
    assert a != b
    assert len(a) == 64
    int(a, 16)  # must be valid hex


def test_hash_api_token_is_deterministic():
    token = generate_api_token()
    assert hash_api_token(token) == hash_api_token(token)
    assert hash_api_token(token) != hash_api_token(generate_api_token())


async def test_authenticate_user_success(db_session):
    user = new_bossman_user(owned_name("alice"), "s3cret!", role="operator")
    db_session.add(user)
    await db_session.flush()

    got = await authenticate_user(db_session, user.username, "s3cret!")
    assert got.username == user.username

    await db_session.delete(user)
    await db_session.commit()


async def test_authenticate_user_wrong_password_fails(db_session):
    user = new_bossman_user(owned_name("bob"), "s3cret!")
    db_session.add(user)
    await db_session.flush()

    with pytest.raises(AuthError):
        await authenticate_user(db_session, user.username, "wrong")

    await db_session.delete(user)
    await db_session.commit()


async def test_authenticate_user_unknown_username_fails(db_session):
    with pytest.raises(AuthError, match="invalid username or password"):
        await authenticate_user(db_session, "no-such-user", "whatever")


async def test_new_api_token_and_authenticate_success(db_session):
    row, raw = new_api_token("ci-bot")
    db_session.add(row)
    await db_session.flush()

    got = await authenticate_api_token(db_session, raw)
    assert got.name == "ci-bot"
    assert got.id == row.id

    await db_session.delete(row)
    await db_session.commit()


async def test_authenticate_api_token_unknown_fails(db_session):
    with pytest.raises(AuthError, match="invalid or revoked"):
        await authenticate_api_token(db_session, "not-a-real-token")


async def test_authenticate_api_token_revoked_fails(db_session):
    row, raw = new_api_token("revoked-bot")
    db_session.add(row)
    await db_session.flush()
    await revoke_api_token(db_session, row)
    await db_session.flush()

    with pytest.raises(AuthError, match="invalid or revoked"):
        await authenticate_api_token(db_session, raw)

    await db_session.delete(row)
    await db_session.commit()


async def test_resolve_identity_jwt_path(db_session):
    settings = _settings()
    user = BossmanUser(username="carol", password_hash="x", role="admin")
    token = create_access_token(user, settings)

    identity = await resolve_identity(db_session, settings, token)

    assert identity.kind == "user"
    assert identity.name == "carol"
    assert identity.role == "admin"


async def test_resolve_identity_api_token_path(db_session):
    settings = _settings()
    row, raw = new_api_token("mcp-facade")
    db_session.add(row)
    await db_session.flush()

    identity = await resolve_identity(db_session, settings, raw)

    assert identity.kind == "api_token"
    assert identity.name == "mcp-facade"

    await db_session.delete(row)
    await db_session.commit()


async def test_resolve_identity_garbage_token_fails(db_session):
    with pytest.raises(AuthError):
        await resolve_identity(db_session, _settings(), "complete-garbage")
