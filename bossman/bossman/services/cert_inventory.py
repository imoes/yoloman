"""Certificate / expiry inventory (gap #10): a fleet-wide board of TLS
certificates and other expiring things, sorted by soonest expiry, alerting
before they lapse.

A `tls` target is probed by Bossman: an unverified TLS handshake to the
endpoint reads the leaf certificate's notAfter, subject, issuer, SANs and
serial (unverified so we can still report expired/self-signed/misconfigured
certs — the whole point). A `manual` target just tracks a hand-entered expiry
date (software licences, domain registrations, anything non-TLS). Crossing
warn_days / crit_days raises a NotifyEvent through the existing channels.
"""

from __future__ import annotations

import asyncio
import ipaddress
import logging
import ssl
from datetime import datetime, timezone
from urllib.parse import urlsplit

from cryptography import x509
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from bossman.config import Settings
from bossman.db.models import CertTarget
from bossman.services import notification

logger = logging.getLogger(__name__)

# For deciding whether a status change is a worsening (alert) or a recovery.
_RANK = {"ok": 0, "unknown": 0, "warning": 1, "error": 2, "critical": 3, "expired": 4}


def parse_endpoint(endpoint: str) -> tuple[str, int]:
    """Turn an endpoint into (host, port). Accepts `https://host[:port]/path`,
    `host:port`, or a bare `host` (defaults to 443)."""
    ep = (endpoint or "").strip()
    if "://" in ep:
        u = urlsplit(ep)
        return u.hostname or "", u.port or 443
    if ep.count(":") == 1:  # host:port (not an IPv6 literal)
        host, _, port = ep.partition(":")
        return host, int(port) if port.isdigit() else 443
    return ep, 443


def _cn(name: x509.Name) -> str:
    """The common name of an X.509 name, falling back to its RFC4514 string."""
    try:
        attrs = name.get_attributes_for_oid(x509.oid.NameOID.COMMON_NAME)
        if attrs:
            return attrs[0].value
    except Exception:  # noqa: BLE001
        pass
    return name.rfc4514_string()


def _not_after(cert: x509.Certificate) -> datetime:
    na = getattr(cert, "not_valid_after_utc", None) or cert.not_valid_after
    return na if na.tzinfo else na.replace(tzinfo=timezone.utc)


def _not_before(cert: x509.Certificate) -> datetime:
    nb = getattr(cert, "not_valid_before_utc", None) or cert.not_valid_before
    return nb if nb.tzinfo else nb.replace(tzinfo=timezone.utc)


def _sans(cert: x509.Certificate) -> list[str]:
    try:
        ext = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName)
        return ext.value.get_values_for_type(x509.DNSName)
    except x509.ExtensionNotFound:
        return []
    except Exception:  # noqa: BLE001
        return []


async def probe_tls(host: str, port: int, timeout: float = 10.0) -> dict:
    """Open an unverified TLS connection and return the leaf cert's fields.
    Raises on connect/handshake failure."""
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    # SNI: send the hostname unless it's a bare IP (SNI must be a name).
    try:
        ipaddress.ip_address(host)
        server_hostname = None
    except ValueError:
        server_hostname = host

    reader, writer = await asyncio.wait_for(
        asyncio.open_connection(host, port, ssl=ctx, server_hostname=server_hostname), timeout
    )
    try:
        sslobj = writer.get_extra_info("ssl_object")
        der = sslobj.getpeercert(binary_form=True)
    finally:
        writer.close()
        try:
            await asyncio.wait_for(writer.wait_closed(), 2.0)
        except Exception:  # noqa: BLE001
            pass
    cert = x509.load_der_x509_certificate(der)
    return {
        "subject": _cn(cert.subject),
        "issuer": _cn(cert.issuer),
        "serial": format(cert.serial_number, "x"),
        "not_before": _not_before(cert),
        "not_after": _not_after(cert),
        "sans": _sans(cert),
    }


def compute_status(days_left: int | None, warn_days: int, crit_days: int) -> str:
    if days_left is None:
        return "unknown"
    if days_left < 0:
        return "expired"
    if days_left <= crit_days:
        return "critical"
    if days_left <= warn_days:
        return "warning"
    return "ok"


async def _maybe_alert(session: AsyncSession, settings: Settings, target: CertTarget, old_status: str) -> None:
    """Alert on a worsening transition; send a recovery when it returns to ok."""
    old_rank, new_rank = _RANK.get(old_status, 0), _RANK.get(target.status, 0)
    if new_rank == old_rank:
        return
    detail = target.last_error or (
        f"{target.days_left} days left"
        + (f" (expires {target.not_after.date().isoformat()})" if target.not_after else "")
    )
    if new_rank > old_rank and new_rank >= 1:
        state = "CRIT" if new_rank >= 3 or target.status == "error" else "WARN"
        await notification.dispatch(session, settings, notification.NotifyEvent(
            agent_name=target.name, service_name=f"Certificate: {target.name}",
            state=state, event="problem", output=detail,
        ))
    elif new_rank == 0 and old_rank >= 1:
        await notification.dispatch(session, settings, notification.NotifyEvent(
            agent_name=target.name, service_name=f"Certificate: {target.name}",
            state="OK", event="recovery", output=detail,
        ))


async def evaluate_target(session: AsyncSession, settings: Settings, target: CertTarget, *, commit: bool = True) -> None:
    """Refresh one target: probe a TLS endpoint (or recompute a manual expiry),
    update its observed fields + status, and alert on a worsening transition."""
    old_status = target.status
    now = datetime.now(timezone.utc)
    if target.kind == "tls":
        host, port = parse_endpoint(target.endpoint)
        if not host:
            target.status, target.last_error = "error", "no host in endpoint"
        else:
            try:
                info = await probe_tls(host, port)
                target.subject = info["subject"]
                target.issuer = info["issuer"]
                target.serial = info["serial"]
                target.not_before = info["not_before"]
                target.not_after = info["not_after"]
                target.sans = info["sans"]
                target.days_left = (info["not_after"] - now).days
                target.status = compute_status(target.days_left, target.warn_days, target.crit_days)
                target.last_error = None
            except Exception as exc:  # noqa: BLE001
                target.status = "error"
                target.last_error = f"{type(exc).__name__}: {str(exc)[:160]}"
    else:  # manual
        if target.not_after is not None:
            na = target.not_after if target.not_after.tzinfo else target.not_after.replace(tzinfo=timezone.utc)
            target.days_left = (na - now).days
            target.status = compute_status(target.days_left, target.warn_days, target.crit_days)
            target.last_error = None
        else:
            target.status, target.days_left = "unknown", None
    target.last_checked_at = now
    await _maybe_alert(session, settings, target, old_status)
    if commit:
        await session.commit()


async def evaluate_all(session: AsyncSession, settings: Settings, tenant_id=None) -> int:
    stmt = select(CertTarget).where(CertTarget.enabled.is_(True))
    if tenant_id is not None:
        stmt = stmt.where(CertTarget.tenant_id == tenant_id)
    targets = (await session.scalars(stmt)).all()
    for t in targets:
        await evaluate_target(session, settings, t, commit=False)
    await session.commit()
    return len(targets)


async def cert_inventory_loop(
    session_factory: async_sessionmaker[AsyncSession], settings: Settings, stop_event
) -> None:
    """Periodically re-probe all enabled cert targets. Guarded by
    settings.cert_inventory_enabled; interval cert_inventory_interval_seconds."""
    if not settings.cert_inventory_enabled:
        return
    interval = max(60, settings.cert_inventory_interval_seconds)
    while not stop_event.is_set():
        try:
            async with session_factory() as session:
                await evaluate_all(session, settings)
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001
            logger.exception("cert-inventory cycle failed")
        try:
            await asyncio.wait_for(stop_event.wait(), timeout=interval)
        except asyncio.TimeoutError:
            pass
