"""Tests for the CVE feed parsers (Block 4-B)."""

import json

from bossman.services.cve_feed import CveFeed


def _feed():
    class _S:
        cve_cache_dir = "/tmp/cve-cache-test"
    return CveFeed(_S())


def test_parse_debian_indexes_by_release_and_source():
    raw = json.dumps({
        "openssl": {
            "CVE-2024-0001": {
                "description": "bad",
                "releases": {
                    "trixie": {"status": "resolved", "fixed_version": "3.0.1-1", "urgency": "high"},
                    "bookworm": {"status": "open", "fixed_version": "0", "urgency": "not yet assigned"},
                },
            },
            "CVE-2024-0002": {
                "releases": {"trixie": {"status": "open", "fixed_version": "", "urgency": "low"}},
            },
        },
        "notes": "ignored non-dict",
    }).encode()
    idx = CveFeed._parse_debian(raw)
    trixie = idx["trixie"]["openssl"]
    cves = {a["cve"]: a for a in trixie}
    assert cves["CVE-2024-0001"]["fixed_version"] == "3.0.1-1"
    assert cves["CVE-2024-0001"]["severity"] == "important"  # high -> important
    assert cves["CVE-2024-0002"]["fixed_version"] == ""  # open, no fix yet
    # fixed_version "0" (not affected) is dropped for bookworm.
    assert "bookworm" not in idx or "openssl" not in idx.get("bookworm", {})


def test_parse_ubuntu_notices():
    raw = json.dumps({
        "notices": [
            {
                "id": "USN-1",
                "cves_ids": ["CVE-2024-1111"],
                "release_packages": {
                    "jammy": [{"name": "curl", "version": "7.81.0-1ubuntu1.15"}],
                },
            }
        ]
    }).encode()
    idx = CveFeed._parse_ubuntu(raw)
    adv = idx["jammy"]["curl"]
    assert adv[0]["cve"] == "CVE-2024-1111"
    assert adv[0]["fixed_version"] == "7.81.0-1ubuntu1.15"


def test_lookup_after_store():
    feed = _feed()
    feed._debian = {"trixie": {"openssl": [{"cve": "CVE-2024-0001", "fixed_version": "3.0.1-1", "severity": "important"}]}}
    assert feed.lookup("debian", "trixie", "openssl")[0]["cve"] == "CVE-2024-0001"
    assert feed.lookup("debian", "trixie", "bash") == []
    assert feed.has("debian") is True
    assert feed.has("ubuntu") is False
