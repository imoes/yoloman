"""Tests for CVE correlation (Block 4-C)."""

from bossman.services.cve_correlate import correlate, release_codename


class FakeFeed:
    def __init__(self, index):
        self._index = index  # {distro: {release: {src: [adv]}}}

    def has(self, distro):
        return distro in self._index

    def lookup(self, distro, release, src):
        return self._index.get(distro, {}).get(release, {}).get(src, [])


def test_release_codename_explicit_and_derived():
    assert release_codename({"distribution": "debian", "codename": "trixie"}) == ("debian", "trixie")
    # derived from version when codename missing
    assert release_codename({"distribution": "debian", "distribution_version": "12"}) == ("debian", "bookworm")
    assert release_codename({"distribution": "ubuntu", "distribution_version": "22.04"}) == ("ubuntu", "jammy")


def test_apt_correlation_version_window():
    feed = FakeFeed({"debian": {"trixie": {"openssl": [
        {"cve": "CVE-2024-1", "fixed_version": "3.0.2-1", "severity": "important"},
        {"cve": "CVE-2024-2", "fixed_version": "3.0.0-1", "severity": "low"},   # already fixed (before current)
        {"cve": "CVE-2024-3", "fixed_version": "9.9.9-1", "severity": "high"},   # beyond candidate
        {"cve": "CVE-2024-4", "fixed_version": "", "severity": ""},              # open, no fix
    ]}}})
    updates = {
        "manager": "apt", "distribution": "debian", "codename": "trixie",
        "updates": [{"name": "openssl", "source": "openssl", "current": "3.0.1-1", "candidate": "3.0.2-1"}],
    }
    cves = {r["cve"] for r in correlate(feed, updates)}
    assert cves == {"CVE-2024-1"}  # only the one crossed by 3.0.1 -> 3.0.2


def test_apt_uses_source_package():
    feed = FakeFeed({"debian": {"bookworm": {"glibc": [
        {"cve": "CVE-2024-9", "fixed_version": "2.36-9", "severity": "important"},
    ]}}})
    updates = {
        "manager": "apt", "distribution": "debian", "distribution_version": "12",
        "updates": [{"name": "libc6", "source": "glibc", "current": "2.36-8", "candidate": "2.36-9"}],
    }
    rows = correlate(feed, updates)
    assert rows and rows[0]["cve"] == "CVE-2024-9" and rows[0]["package"] == "libc6"


def test_dnf_uses_agent_cves():
    updates = {
        "manager": "dnf",
        "updates": [{"name": "openssl.x86_64", "current": "1", "candidate": "2", "cves": ["CVE-2024-5"], "severity": "important"}],
    }
    rows = correlate(None, updates)
    assert rows[0]["cve"] == "CVE-2024-5" and rows[0]["distro"] == "redhat" and rows[0]["severity"] == "important"


def test_no_codename_no_results():
    feed = FakeFeed({"debian": {"trixie": {"x": [{"cve": "C", "fixed_version": "1", "severity": ""}]}}})
    assert correlate(feed, {"manager": "apt", "distribution": "debian", "updates": [{"name": "x", "current": "0", "candidate": "1"}]}) == []
