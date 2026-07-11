"""CVE feed cache (Block 4-B).

Fetches distro security trackers and indexes them so a host's pending package
updates can be correlated to the CVEs they fix. The index is held in memory
(fast per-host correlation) and mirrored to an on-disk raw cache so a Bossman
restart doesn't re-download tens of megabytes.

Shape of the in-memory index, per distro:

    { release_codename: { source_package: [ Advisory, ... ] } }

where an Advisory is a dict {cve, fixed_version, severity}. ``fixed_version``
may be "" when the tracker lists a CVE as open with no fix yet.

Debian: the security-tracker ``data/json`` (~78 MB) keyed source_pkg → CVE →
releases → {status, fixed_version, urgency}. Ubuntu: USN ``notices.json``
(notice → release_packages + cves). RHEL correlation is agent-driven (dnf
updateinfo already maps package→CVE offline), so it is handled in the
correlator, not here.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
from dataclasses import dataclass, field
from typing import Any

import httpx

logger = logging.getLogger("bossman.cve_feed")

Advisory = dict[str, str]  # {cve, fixed_version, severity}
Index = dict[str, dict[str, list[Advisory]]]  # release -> src_pkg -> advisories


@dataclass
class CveFeedStats:
    last_run_started: str | None = None
    last_run_ok: bool | None = None
    last_error: str | None = None
    counts: dict[str, int] = field(default_factory=dict)  # distro -> advisory count


class CveFeed:
    """Holds the per-distro CVE indexes and refreshes them from the trackers."""

    def __init__(self, settings, stats: CveFeedStats | None = None):
        self.settings = settings
        self.stats = stats or CveFeedStats()
        self._debian: Index = {}
        self._ubuntu: Index = {}

    # ---- lookup (used by the correlator) ----

    def lookup(self, distro: str, release: str, source_package: str) -> list[Advisory]:
        idx = self._index_for(distro)
        return idx.get(release, {}).get(source_package, [])

    def has(self, distro: str) -> bool:
        return bool(self._index_for(distro))

    def _index_for(self, distro: str) -> Index:
        if distro in ("debian", "raspbian"):
            return self._debian
        if distro in ("ubuntu", "linuxmint"):
            return self._ubuntu
        return {}

    # ---- refresh ----

    async def refresh(self) -> None:
        os.makedirs(self.settings.cve_cache_dir, exist_ok=True)
        errors: list[str] = []
        async with httpx.AsyncClient(timeout=httpx.Timeout(300.0)) as client:
            for distro, url, parse in (
                ("debian", self.settings.cve_debian_url, self._parse_debian),
                ("ubuntu", self.settings.cve_ubuntu_url, self._parse_ubuntu),
            ):
                try:
                    raw = await self._fetch(client, url)
                    idx = parse(raw)
                    self._store(distro, idx)
                    self._write_cache(distro, raw)
                    self.stats.counts[distro] = sum(len(v) for r in idx.values() for v in r.values())
                    logger.info("cve_feed refreshed %s: %d advisories", distro, self.stats.counts[distro])
                except Exception as exc:  # noqa: BLE001 — one distro's failure must not sink the others
                    errors.append(f"{distro}: {exc}")
                    logger.warning("cve_feed refresh failed for %s", distro, exc_info=True)
        self.stats.last_error = "; ".join(errors) if errors else None
        self.stats.last_run_ok = not errors

    async def _fetch(self, client: httpx.AsyncClient, url: str) -> bytes:
        resp = await client.get(url, follow_redirects=True)
        resp.raise_for_status()
        return resp.content

    def _store(self, distro: str, idx: Index) -> None:
        if distro == "debian":
            self._debian = idx
        elif distro == "ubuntu":
            self._ubuntu = idx

    # ---- disk cache ----

    def _cache_path(self, distro: str) -> str:
        return os.path.join(self.settings.cve_cache_dir, f"{distro}.json")

    def _write_cache(self, distro: str, raw: bytes) -> None:
        try:
            with open(self._cache_path(distro), "wb") as fh:
                fh.write(raw)
        except OSError:
            logger.warning("cve_feed could not write cache for %s", distro, exc_info=True)

    def load_from_cache(self) -> None:
        """Populate indexes from any on-disk cache (fast startup, offline-safe)."""
        for distro, parse in (("debian", self._parse_debian), ("ubuntu", self._parse_ubuntu)):
            path = self._cache_path(distro)
            if not os.path.exists(path):
                continue
            try:
                with open(path, "rb") as fh:
                    self._store(distro, parse(fh.read()))
                self.stats.counts[distro] = sum(len(v) for r in self._index_for(distro).values() for v in r.values())
            except Exception:  # noqa: BLE001
                logger.warning("cve_feed could not load cache for %s", distro, exc_info=True)

    # ---- parsers ----

    @staticmethod
    def _parse_debian(raw: bytes) -> Index:
        data: dict[str, Any] = json.loads(raw)
        idx: Index = {}
        for src_pkg, cves in data.items():
            if not isinstance(cves, dict):
                continue
            for cve, info in cves.items():
                if not cve.startswith("CVE-") or not isinstance(info, dict):
                    continue
                for release, rel in (info.get("releases") or {}).items():
                    if not isinstance(rel, dict):
                        continue
                    fixed = rel.get("fixed_version", "") or ""
                    # 0 means "not affected / not applicable" in the tracker.
                    if fixed == "0":
                        continue
                    urgency = rel.get("urgency", "") or ""
                    idx.setdefault(release, {}).setdefault(src_pkg, []).append(
                        {"cve": cve, "fixed_version": fixed, "severity": _debian_severity(urgency)}
                    )
        return idx

    @staticmethod
    def _parse_ubuntu(raw: bytes) -> Index:
        data: dict[str, Any] = json.loads(raw)
        notices = data.get("notices", data if isinstance(data, list) else [])
        idx: Index = {}
        for n in notices:
            if not isinstance(n, dict):
                continue
            cves = n.get("cves_ids") or n.get("cves") or []
            cves = [c for c in cves if isinstance(c, str) and c.startswith("CVE-")]
            rel_pkgs = n.get("release_packages") or {}
            for release, pkgs in rel_pkgs.items():
                for pkg in pkgs or []:
                    if not isinstance(pkg, dict):
                        continue
                    name = pkg.get("name")
                    version = pkg.get("version", "") or ""
                    if not name:
                        continue
                    for cve in cves:
                        idx.setdefault(release, {}).setdefault(name, []).append(
                            {"cve": cve, "fixed_version": version, "severity": ""}
                        )
        return idx


# Debian urgency → a common severity vocabulary (matches Red Hat's tiers).
_DEBIAN_URGENCY = {
    "high": "important",
    "medium": "moderate",
    "low": "low",
    "unimportant": "low",
}


def _debian_severity(urgency: str) -> str:
    u = (urgency or "").split("**")[0].strip().lower()
    return _DEBIAN_URGENCY.get(u, "")


async def cve_feed_loop(feed: CveFeed, settings, stop_event: asyncio.Event) -> None:
    """Background loop: refresh the CVE feeds every cve_feed_interval_hours,
    mirroring the poller/reconciler loop pattern. Skips entirely when disabled."""
    if not settings.cve_feed_enabled:
        return
    # A first refresh soon after startup, unless the disk cache is already warm.
    if not (feed.has("debian") or feed.has("ubuntu")):
        try:
            await feed.refresh()
        except Exception:  # noqa: BLE001
            logger.warning("initial cve_feed refresh failed", exc_info=True)
    interval = max(1, settings.cve_feed_interval_hours) * 3600
    while not stop_event.is_set():
        try:
            await asyncio.wait_for(stop_event.wait(), timeout=interval)
        except asyncio.TimeoutError:
            pass
        if stop_event.is_set():
            return
        try:
            await feed.refresh()
        except Exception:  # noqa: BLE001
            logger.warning("cve_feed refresh failed", exc_info=True)
