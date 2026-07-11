"""CVE correlation (Block 4-C).

Given a host's facts + its package_updates tool output and the cached CVE feed,
work out which CVEs each pending upgrade would fix:

- apt / Ubuntu: look the update's *source* package up in the feed for the
  host's release codename; a CVE is fixed by the upgrade when the tracker's
  ``fixed_version`` is newer than the installed version and no newer than the
  candidate (dpkg version ordering).
- dnf / yum: the agent's ``dnf updateinfo`` already maps package → CVE + a
  severity offline, so those are taken directly (feed lookup not needed).

Returns a list of plain dicts ready to insert as HostCve rows.
"""

from __future__ import annotations

from .version_compare import dpkg_compare

# os-release VERSION_ID → release codename, when the agent didn't report a
# VERSION_CODENAME (older releases, minimal images).
_DEBIAN_CODENAME = {"10": "buster", "11": "bullseye", "12": "bookworm", "13": "trixie", "14": "forky"}
_UBUNTU_CODENAME = {"18.04": "bionic", "20.04": "focal", "22.04": "jammy", "24.04": "noble", "24.10": "oracular"}


def release_codename(updates: dict) -> tuple[str, str]:
    """Return (distro, codename) for feed lookup, deriving the codename from
    the distribution_version when the agent didn't report one. Reads the
    distribution fields the package_updates module carries on its list result."""
    distro = (updates.get("distribution") or "").lower()
    codename = (updates.get("codename") or "").lower()
    version = str(updates.get("distribution_version") or "")
    if not codename:
        if distro in ("debian", "raspbian"):
            codename = _DEBIAN_CODENAME.get(version.split(".")[0], "")
        elif distro in ("ubuntu", "linuxmint"):
            codename = _UBUNTU_CODENAME.get(version, "")
    return distro, codename


def correlate(feed, updates: dict) -> list[dict]:
    """Correlate one host. `updates` is the package_updates tool's `data`."""
    manager = updates.get("manager", "")
    items = updates.get("updates", []) or []
    if manager in ("dnf", "yum"):
        return _correlate_dnf(items)
    if manager == "apt":
        return _correlate_apt(feed, updates, items)
    return []


def _correlate_dnf(items: list[dict]) -> list[dict]:
    out: list[dict] = []
    for u in items:
        for cve in u.get("cves", []) or []:
            out.append({
                "cve": cve,
                "package": u.get("name", ""),
                "source_package": u.get("name", ""),
                "current_version": u.get("current", ""),
                "fixed_version": u.get("candidate", ""),
                "severity": u.get("severity", ""),
                "distro": "redhat",
            })
    return out


def _correlate_apt(feed, updates: dict, items: list[dict]) -> list[dict]:
    distro, codename = release_codename(updates)
    if not codename or not feed.has(distro):
        return []
    out: list[dict] = []
    seen: set[tuple[str, str]] = set()  # (cve, package) dedup
    for u in items:
        name = u.get("name", "")
        source = u.get("source") or name
        current = u.get("current", "")
        candidate = u.get("candidate", "")
        for adv in feed.lookup(distro, codename, source):
            fixed = adv.get("fixed_version", "")
            if not fixed:
                continue  # open CVE, no fix available — an upgrade can't close it
            # The upgrade closes the CVE iff installed < fixed <= candidate.
            if current and dpkg_compare(current, fixed) >= 0:
                continue  # already at/after the fix
            if candidate and dpkg_compare(candidate, fixed) < 0:
                continue  # the candidate still doesn't reach the fix
            key = (adv["cve"], name)
            if key in seen:
                continue
            seen.add(key)
            out.append({
                "cve": adv["cve"],
                "package": name,
                "source_package": source,
                "current_version": current,
                "fixed_version": fixed,
                "severity": adv.get("severity", ""),
                "distro": distro,
            })
    return out
