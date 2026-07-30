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

# cve -> one-line human description, populated from the Debian tracker on parse.
# Module-level (not persisted): repopulated on each feed refresh; the UI falls
# back to a tracker link when a description isn't loaded (e.g. cache-only start).
_CVE_DESCRIPTIONS: dict[str, str] = {}


def cve_description(cve: str) -> str:
    return _CVE_DESCRIPTIONS.get(cve, "")


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
        try:
            os.makedirs(self.settings.cve_cache_dir, exist_ok=True)
        except OSError:
            logger.warning("cve_feed cache dir not writable (%s); in-memory only", self.settings.cve_cache_dir)
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
                # Stash the human description so a CVE number becomes meaningful
                # in the UI (the Debian tracker carries a one-line summary).
                desc = (info.get("description") or "").strip()
                if desc:
                    _CVE_DESCRIPTIONS[cve] = desc
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
# Debian's tracker urgency -> our severity vocabulary.
#
# Two of these mappings were wrong, and the numbers say why (counted over the
# cached tracker for trixie):
#
#   not yet assigned  42968   Debian has not triaged the CVE yet. It used to fall
#                             through to "", which the UI renders as "unknown" —
#                             indistinguishable from "we failed to look it up".
#                             It is a real, reportable state and gets its own value.
#   unimportant        8361   Debian says this has NO security impact for Debian
#                             (the vulnerable path is not reachable as shipped).
#                             It used to be mapped to "low", presenting 8361
#                             non-issues as minor vulnerabilities.
#   low                2714
#   medium              658
#   high                133
#
# So ~80% of Debian CVEs carry no severity at all. That is Debian's reality, not a
# defect on our side: the tracker JSON has no CVSS and no NVD severity — the only
# fields per release are fixed_version / next_point_update / nodsa / nodsa_reason /
# repositories / status / urgency. Showing a real severity for the untriaged 80%
# would need a second source (NVD), which is a feature, not a fix.
#
# Deliberately NOT done: falling back to another release's urgency for the same CVE.
# Checked — the other releases mostly say "end-of-life" (821) or "unimportant" (87),
# i.e. release-specific judgements that do not transfer.
_DEBIAN_URGENCY = {
    "high": "important",
    "medium": "moderate",
    "low": "low",
    "unimportant": "unimportant",
    "not yet assigned": "untriaged",
    "end-of-life": "untriaged",
}


def _debian_severity(urgency: str) -> str:
    """Map a tracker urgency to our vocabulary; an unknown one is untriaged, not "".

    Defaulting to "untriaged" rather than "" keeps "Debian has not judged this" apart
    from "there is no data", and makes a future urgency value show up as untriaged
    instead of silently vanishing.
    """
    u = (urgency or "").split("**")[0].strip().lower()
    if not u:
        return ""
    return _DEBIAN_URGENCY.get(u, "untriaged")


async def cve_feed_loop(feed: CveFeed, settings, stop_event: asyncio.Event, after_refresh=None) -> None:
    """Background loop: refresh the CVE feeds every cve_feed_interval_hours,
    mirroring the poller/reconciler loop pattern. Skips entirely when disabled.
    ``after_refresh`` (optional async callable) runs after each successful
    refresh — used to sweep the fleet and persist per-host CVE correlations."""
    if not settings.cve_feed_enabled:
        return

    async def _refresh_and_collect(initial: bool) -> None:
        try:
            await feed.refresh()
        except Exception:  # noqa: BLE001
            logger.warning("cve_feed refresh failed", exc_info=True)
            return
        if after_refresh is not None:
            try:
                await after_refresh()
            except Exception:  # noqa: BLE001
                logger.warning("cve collect after refresh failed", exc_info=True)

    # Startup: refresh only when the cache is cold, but ALWAYS correlate.
    #
    # These are two different questions and conflating them left host_cves empty
    # indefinitely: the feed cache is a file that survives everything (79 MB of
    # debian.json), while the correlations live in the DB and disappear with a rebuild,
    # a new host, or a fresh install. Skipping the collect because the FEED was warm
    # meant a restart did nothing and the first correlation waited a full
    # cve_feed_interval_hours — and every restart pushed that deadline out again, so on
    # a frequently-restarted server it never ran at all. Verified: host_cves had 0 rows
    # with a warm Jul-17 feed and a DB rebuilt Jul-28.
    if not (feed.has("debian") or feed.has("ubuntu")):
        await _refresh_and_collect(initial=True)
    elif after_refresh is not None:
        try:
            await after_refresh()
        except Exception:  # noqa: BLE001 — a failed sweep must not kill the loop
            logger.warning("cve collect on startup (warm cache) failed", exc_info=True)
    interval = max(1, settings.cve_feed_interval_hours) * 3600
    while not stop_event.is_set():
        try:
            await asyncio.wait_for(stop_event.wait(), timeout=interval)
        except asyncio.TimeoutError:
            pass
        if stop_event.is_set():
            return
        await _refresh_and_collect(initial=False)
