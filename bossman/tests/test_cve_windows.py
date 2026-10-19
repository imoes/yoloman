"""Windows CVEs (plan B13 step 2): MSRC CVRF → KB index, and a Windows host's pending updates → HostCve rows.

The CVRF snippets have the real document's shape (Vulnerability → Threats Type 3 = severity per product,
Remediations Type 2 = vendor fix whose description is the KB number) — trimmed from the 2026-Sep document.
"""

import json

import httpx
import pytest

from bossman.services.cve_correlate import correlate_windows
from bossman.services.cve_feed import CveFeed, merge_msrc

SERVER, CORE = "12244", "12245"


def vuln(cve, kb, sev_by_product, title="Windows Storage Elevation of Privilege Vulnerability"):
    return {"CVE": cve, "Title": {"Value": title},
            "Threats": [{"Type": 0, "Description": {}, "ProductID": [SERVER]}]
                       + [{"Type": 3, "Description": {"Value": s}, "ProductID": [p]} for p, s in sev_by_product.items()],
            "Remediations": [{"Type": 2, "Description": {"Value": kb}, "ProductID": list(sev_by_product), "SubType": "Security Update"},
                             {"Type": 2, "Description": {"Value": "Release Notes"}, "ProductID": [SERVER]},
                             {"Type": 3, "URL": "https://example", "ProductID": [SERVER]}]}


def test_the_kb_index_keeps_msrc_words_and_the_highest_severity_across_products():
    idx = {}
    merge_msrc(idx, {"Vulnerability": [
        vuln("CVE-2026-1", "5122882", {SERVER: "Important", CORE: "Critical"}),
        vuln("CVE-2026-2", "5122882", {SERVER: "Moderate"}),
        {"CVE": "not-a-cve", "Remediations": []},
    ]})
    assert idx == {"KB5122882": {
        "CVE-2026-1": {"severity": "Critical", "title": "Windows Storage Elevation of Privilege Vulnerability"},
        "CVE-2026-2": {"severity": "Moderate", "title": "Windows Storage Elevation of Privilege Vulnerability"}}}


class _S:
    cve_cache_dir = "/tmp/cve-cache-test-windows"
    cve_msrc_url = "https://msrc.example/cvrf/v3.0"
    cve_msrc_months = 2


def _feed(index):
    f = CveFeed(_S())
    f._msrc = index
    return f


FACTS = {"pending": [
    {"kb": "KB5122882", "title": "2026-09 Kumulatives Update (KB5122882)", "cve_ids": [], "msrc_severity": "unrated"},
    {"kb": "KB5128928", "title": ".NET (KB5128928)", "cve_ids": [], "msrc_severity": "Important"},
    {"kb": "KB9999999", "title": "an update that names its CVE", "cve_ids": ["CVE-2026-9"], "msrc_severity": "Low"},
]}


def test_a_windows_host_gets_rows_from_msrc_and_names_what_has_none():
    feed = _feed({"KB5122882": {"CVE-2026-1": {"severity": "Critical", "title": "t"}}})
    rows, unmapped = correlate_windows(feed, FACTS)
    assert {(r["cve"], r["package"], r["severity"]) for r in rows} == {
        ("CVE-2026-1", "KB5122882", "Critical"),        # from Microsoft's data
        ("CVE-2026-9", "KB9999999", "Low")}              # the host's own CVE id wins when Windows gives one
    assert all(r["distro"] == "windows" and r["fixed_version"] == r["package"] for r in rows)
    assert unmapped == ["KB5128928"]                     # said, not dropped


def test_without_the_msrc_index_every_unnamed_update_is_unmapped():
    rows, unmapped = correlate_windows(_feed({}), FACTS)
    assert [r["cve"] for r in rows] == ["CVE-2026-9"] and unmapped == ["KB5122882", "KB5128928"]


async def test_refresh_reads_the_newest_months_and_caches_the_compact_index(tmp_path, monkeypatch):
    class S(_S):
        cve_cache_dir = str(tmp_path)
        cve_debian_url = cve_ubuntu_url = "https://unused.example/"
    docs = {"2026-Aug": [vuln("CVE-2026-0", "5100000", {SERVER: "Low"})],
            "2026-Sep": [vuln("CVE-2026-1", "5122882", {SERVER: "Important"})],
            "2026-Oct": [vuln("CVE-2026-2", "5130000", {SERVER: "Critical"})]}

    def handler(req: httpx.Request) -> httpx.Response:
        if req.url.path.endswith("/updates"):
            dates = {"2026-Aug": "2026-08-11T07:00:00Z", "2026-Sep": "2026-09-08T07:00:00Z", "2026-Oct": "2026-10-13T07:00:00Z"}
            return httpx.Response(200, json={"value": [{"ID": m, "InitialReleaseDate": dates[m]} for m in ("2026-Oct", "2026-Aug", "2026-Sep")]})
        m = req.url.path.rsplit("/", 1)[-1]
        if m in docs:
            return httpx.Response(200, json={"Vulnerability": docs[m]})
        return httpx.Response(404)

    real = httpx.AsyncClient
    monkeypatch.setattr(httpx, "AsyncClient", lambda **kw: real(transport=httpx.MockTransport(handler)))
    feed = CveFeed(S())
    await feed.refresh()
    assert feed.msrc_months == ["2026-Sep", "2026-Oct"]          # the newest two by release date, oldest first
    assert feed.lookup_kb("kb5122882")[0]["cve"] == "CVE-2026-1" and feed.lookup_kb("KB5100000") == []
    again = CveFeed(S())
    again.load_from_cache()
    assert again.lookup_kb("KB5130000")[0]["severity"] == "Critical"
    assert "windows (msrc)" not in (feed.stats.last_error or "")
