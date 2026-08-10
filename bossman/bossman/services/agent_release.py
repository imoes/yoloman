"""Agent release channel — detect a new yoloman-agent package on GitHub by hash.

Bossman polls the configured repo's latest release (BOSSMAN_AGENT_RELEASE_REPO,
default imoes/yoloman). Each release carries a `*.manifest.json` asset with the
SHA-256 of the .deb and .rpm, so we learn the newest version AND its hash without
downloading the whole package. The result is cached in memory (refreshed on the
poller's cadence); the API surfaces it plus which enrolled agents are behind, and
a rollout downloads the right asset, VERIFIES its sha256 against the manifest, and
pushes it over the existing mTLS self-update channel. Detection + one-click
rollout — never an unattended push.
"""
from __future__ import annotations

import asyncio
import hashlib
import logging
from dataclasses import asdict, dataclass
from datetime import datetime, timezone

import httpx

from bossman.config import Settings

logger = logging.getLogger(__name__)

_GH_API = "https://api.github.com"


@dataclass
class AssetInfo:
    name: str
    sha256: str
    url: str       # browser_download_url (works for a public repo)
    api_url: str = ""  # api.github.com/…/assets/{id} — authenticated download (private repo)


@dataclass
class ReleaseInfo:
    version: str
    tag: str
    html_url: str
    published_at: str | None
    deb: AssetInfo | None
    rpm: AssetInfo | None


# ── in-memory cache (a cache, not persistent state — re-checked after restart) ──
_lock = asyncio.Lock()
_latest: ReleaseInfo | None = None
_checked_at: datetime | None = None
_error: str | None = None


def _norm_version(tag: str) -> str:
    """`agent-v0.57.43` / `v0.57.43` / `0.57.43` → `0.57.43`."""
    t = (tag or "").strip()
    for prefix in ("agent-v", "agent-", "v"):
        if t.startswith(prefix):
            return t[len(prefix):]
    return t


def _version_tuple(v: str) -> tuple[int, ...]:
    """A best-effort comparable tuple ("0.57.43" → (0,57,43)); non-numeric → (,)."""
    out: list[int] = []
    for part in _norm_version(v).split("."):
        num = "".join(ch for ch in part if ch.isdigit())
        if num == "":
            break
        out.append(int(num))
    return tuple(out)


def is_newer(candidate: str, installed: str) -> bool:
    """True if `candidate` is a strictly newer version than `installed`."""
    ct, it = _version_tuple(candidate), _version_tuple(installed)
    if ct and it:
        return ct > it
    # Fall back to a plain string compare when either side isn't numeric.
    return _norm_version(candidate) != _norm_version(installed) and bool(candidate)


def _gh_headers(settings: Settings) -> dict[str, str]:
    h = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}
    if settings.github_token:
        h["Authorization"] = f"Bearer {settings.github_token}"
    return h


async def _download_asset(client: httpx.AsyncClient, settings: Settings, asset: "AssetInfo") -> bytes:
    """Fetch an asset's bytes. A private repo needs the authenticated asset API
    (Accept: application/octet-stream + token); a public repo can use the plain
    browser_download_url. Prefer the API path whenever a token is configured."""
    if settings.github_token and asset.api_url:
        resp = await client.get(asset.api_url, headers={**_gh_headers(settings), "Accept": "application/octet-stream"})
    else:
        resp = await client.get(asset.url, headers=_gh_headers(settings))
    resp.raise_for_status()
    return resp.content


async def _fetch_latest(settings: Settings) -> ReleaseInfo:
    """Query the repo's releases and build a ReleaseInfo for the newest one that
    actually ships a yoloman-agent package (skips app-only / draft / prerelease)."""
    repo = settings.agent_release_repo
    headers = _gh_headers(settings)
    async with httpx.AsyncClient(timeout=30.0, follow_redirects=True) as client:
        resp = await client.get(f"{_GH_API}/repos/{repo}/releases", headers=headers, params={"per_page": 30})
        resp.raise_for_status()
        releases = resp.json()
        rel = None
        for cand in releases:
            if cand.get("draft") or cand.get("prerelease"):
                continue
            if any(a.get("name", "").startswith("yoloman-agent") for a in cand.get("assets", [])):
                rel = cand
                break
        if rel is None:
            raise RuntimeError(f"no yoloman-agent release found in {repo}")

        assets = rel.get("assets", [])
        by_name = {a.get("name", ""): a for a in assets}

        # The manifest carries the authoritative sha256 of each asset.
        shas: dict[str, str] = {}
        man = next((a for a in assets if a.get("name", "").endswith(".manifest.json")), None)
        if man:
            try:
                man_asset = AssetInfo(name=man["name"], sha256="",
                                      url=man["browser_download_url"], api_url=man.get("url", ""))
                raw = await _download_asset(client, settings, man_asset)
                import json as _json
                data = _json.loads(raw)
                for kind in ("deb", "rpm"):
                    part = data.get(kind) or {}
                    if part.get("name") and part.get("sha256"):
                        shas[part["name"]] = part["sha256"]
            except (httpx.HTTPError, ValueError) as exc:
                logger.warning("agent-release: manifest unreadable: %s", exc)

        def asset_for(suffix: str) -> AssetInfo | None:
            a = next((x for x in assets if x.get("name", "").startswith("yoloman-agent")
                      and x.get("name", "").endswith(suffix)), None)
            if not a:
                return None
            return AssetInfo(name=a["name"], sha256=shas.get(a["name"], ""),
                             url=a["browser_download_url"], api_url=a.get("url", ""))

        return ReleaseInfo(
            version=_norm_version(rel.get("tag_name", "")),
            tag=rel.get("tag_name", ""),
            html_url=rel.get("html_url", ""),
            published_at=rel.get("published_at"),
            deb=asset_for(".deb"),
            rpm=asset_for(".rpm"),
        )


async def refresh(settings: Settings) -> ReleaseInfo | None:
    """Force a re-check now; updates the cache. Returns the latest info or None."""
    global _latest, _checked_at, _error
    async with _lock:
        try:
            info = await _fetch_latest(settings)
            _latest, _error = info, None
        except Exception as exc:  # noqa: BLE001 — network/parse errors are expected, surfaced via _error
            _error = str(exc)[:300]
            logger.warning("agent-release: check failed: %s", _error)
        _checked_at = datetime.now(timezone.utc)
        return _latest


async def maybe_refresh(settings: Settings) -> None:
    """Called from the poller loop each cycle; actually hits GitHub only once per
    agent_release_check_interval_seconds. Cheap no-op the rest of the time."""
    if not settings.agent_release_enabled:
        return
    now = datetime.now(timezone.utc)
    if _checked_at is not None and (now - _checked_at).total_seconds() < settings.agent_release_check_interval_seconds:
        return
    await refresh(settings)


def snapshot() -> dict:
    """The cached view for the API (no network)."""
    return {
        "enabled": True,
        "checked_at": _checked_at.isoformat() if _checked_at else None,
        "error": _error,
        "latest": asdict(_latest) if _latest else None,
    }


async def download_verified(settings: Settings, kind: str) -> tuple[bytes, AssetInfo]:
    """Download the .deb or .rpm of the cached latest release and verify its
    sha256 against the manifest. Raises on mismatch/missing so a rollout never
    pushes an unverified or wrong package."""
    if _latest is None:
        raise RuntimeError("no release info yet — run a check first")
    asset = _latest.deb if kind == "deb" else _latest.rpm
    if asset is None:
        raise RuntimeError(f"latest release has no {kind} asset")
    if not asset.sha256:
        raise RuntimeError(f"{asset.name}: no sha256 in the release manifest — refusing to push an unverified package")
    async with httpx.AsyncClient(timeout=120.0, follow_redirects=True) as client:
        data = await _download_asset(client, settings, asset)
    digest = hashlib.sha256(data).hexdigest()
    if digest != asset.sha256:
        raise RuntimeError(f"{asset.name}: sha256 mismatch (got {digest[:12]}…, want {asset.sha256[:12]}…) — refusing to push")
    return data, asset
