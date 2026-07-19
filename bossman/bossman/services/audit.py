"""Unified audit trail (gap #13): a who-did-what-when log.

Most rows are written automatically by `audit_middleware`, which records every
authenticated *mutating* API call (POST/PUT/PATCH/DELETE) once, with the actor
resolved from the bearer token, the resource from the path, and the outcome from
the response status. Logins are recorded explicitly by the auth route (they have
no bearer yet and are high-value). `record_audit` is the low-level writer and is
best-effort — auditing must never break the request it describes.
"""

from __future__ import annotations

import logging
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import AuditLog

logger = logging.getLogger(__name__)

DEFAULT_TENANT_ID = UUID("00000000-0000-0000-0000-000000000001")

# Mutating methods we audit. GET/HEAD/OPTIONS are reads and are skipped.
_MUTATING = {"POST", "PUT", "PATCH", "DELETE"}

# Path-prefix → category. First match wins; order matters (most specific first).
_CATEGORIES: list[tuple[str, str]] = [
    ("/api/v1/auth", "auth"),
    ("/api/v1/users", "access"),
    ("/api/v1/access-grants", "access"),
    ("/api/v1/api-tokens", "access"),
    ("/api/v1/notification", "policy"),
    ("/api/v1/compliance", "policy"),
    ("/api/v1/cert-targets", "policy"),
    ("/api/v1/scheduled-jobs", "policy"),
    ("/api/v1/check-rules", "policy"),
    ("/api/v1/check-assignments", "policy"),
    ("/api/v1/ou", "policy"),
    ("/api/v1/config-policies", "config"),
    ("/api/v1/config-templates", "config"),
    ("/api/v1/config-codecs", "config"),
    ("/api/v1/host-groups", "policy"),
    ("/api/v1/rollouts", "execution"),
    ("/api/v1/runbooks", "execution"),
    ("/api/v1/runbook-runs", "execution"),
    ("/api/v1/plans", "execution"),
    ("/api/v1/deployments", "execution"),
    ("/api/v1/deploy", "execution"),
    ("/api/v1/runs", "execution"),
    ("/api/v1/agents", "config"),
    ("/api/v1/thresholds", "monitoring"),
    ("/api/v1/checks", "monitoring"),
    ("/api/v1/events", "monitoring"),
]

# Mutating paths that are high-frequency machine traffic, not human actions —
# skip so the trail stays a readable record of operator activity.
_SKIP_PREFIXES = (
    "/api/v1/enroll",
    "/api/v1/agents/report",
    "/api/v1/auth/login",  # recorded explicitly by the auth route (success + failure)
)


def categorize(path: str) -> str:
    for prefix, cat in _CATEGORIES:
        if path.startswith(prefix):
            return cat
    return "other"


def _target_from_path(path: str) -> str | None:
    """The resource tail of an /api/v1/<collection>/<id...> path (the id and any
    sub-resource), or None for a bare collection path."""
    parts = [p for p in path.split("/") if p]
    # parts like ["api","v1","compliance-rules","<id>", ...]
    if len(parts) > 3:
        return "/".join(parts[3:])
    return None


async def record_audit(
    session: AsyncSession,
    *,
    actor: str,
    action: str,
    category: str = "other",
    actor_kind: str | None = None,
    method: str | None = None,
    path: str | None = None,
    target: str | None = None,
    status: str = "ok",
    status_code: int | None = None,
    source_ip: str | None = None,
    detail: dict | None = None,
    tenant_id: UUID = DEFAULT_TENANT_ID,
    commit: bool = True,
) -> None:
    """Write one audit row. Best-effort: never raises into the caller."""
    try:
        session.add(AuditLog(
            tenant_id=tenant_id, actor=actor or "anonymous", actor_kind=actor_kind,
            action=action, category=category, method=method, path=path, target=target,
            status=status, status_code=status_code, source_ip=source_ip, detail=detail or {},
        ))
        if commit:
            await session.commit()
    except Exception:  # noqa: BLE001
        logger.exception("failed to write audit row (%s %s)", action, path)
        if commit:
            try:
                await session.rollback()
            except Exception:  # noqa: BLE001
                pass


async def audit_middleware(request, call_next):
    """@app.middleware('http') handler: records every authenticated mutating API
    call once, after the response. Reads the session factory + settings from
    request.app.state (set in the lifespan). Never fails the request."""
    from bossman.config import get_settings
    from bossman.services.auth import AuthError, resolve_identity

    response = await call_next(request)
    try:
        settings = get_settings()
        session_factory = getattr(request.app.state, "session_factory", None)
        if (
            settings.audit_enabled
            and session_factory is not None
            and request.method in _MUTATING
            and request.url.path.startswith("/api/v1/")
            and not request.url.path.startswith(_SKIP_PREFIXES)
        ):
            actor, actor_kind = "anonymous", None
            auth_header = request.headers.get("authorization", "")
            if auth_header.lower().startswith("bearer "):
                bearer = auth_header[len("bearer "):]
                async with session_factory() as s:
                    try:
                        ident = await resolve_identity(s, settings, bearer)
                        actor, actor_kind = ident.name, ident.kind
                    except AuthError:
                        pass
            path = request.url.path
            code = response.status_code
            async with session_factory() as s:
                await record_audit(
                    s, actor=actor, actor_kind=actor_kind,
                    action=f"{request.method} {path}", category=categorize(path),
                    method=request.method, path=path, target=_target_from_path(path),
                    status="ok" if code < 400 else "failed", status_code=code,
                    source_ip=request.client.host if request.client else None,
                )
    except Exception:  # noqa: BLE001
        logger.exception("audit middleware error")
    return response
