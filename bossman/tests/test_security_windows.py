"""A Windows host in the security view (plan B13 step 2) — DB-backed: collect_host reads windows_update_facts,
correlates against the MSRC index, and the fleet endpoints rank MSRC's "Critical" with RHEL's "critical"."""

from fastapi.testclient import TestClient
from sqlalchemy import delete, select

from bossman.db.models import HostCve
from bossman.main import create_app
from bossman.services.cve_collect import collect_host
from bossman.services.cve_feed import CveFeed
from tests.test_management_api import _headers, _make_agent, _make_api_token


class WindowsUpdateAgent:
    async def call_tool(self, name, body):
        self.calls.append(name)
        return {"changed": False, "data": {"pending": [
            {"kb": "KB5122882", "title": "2026-09 Kumulatives Update (KB5122882)", "cve_ids": [], "msrc_severity": "unrated"},
            {"kb": "KB5128928", "title": ".NET (KB5128928)", "cve_ids": [], "msrc_severity": "Important"}],
            "search_result": self.search}}

    def __init__(self, search="Succeeded"):
        self.calls, self.search = [], search


class _S:
    cve_cache_dir = "/tmp/cve-cache-test-sec"


async def test_a_windows_host_is_collected_through_windows_update_facts(db_session):
    agent = await _make_agent(db_session, facts={"os_family": "windows"})
    feed = CveFeed(_S())
    feed._msrc = {"KB5122882": {"CVE-2026-1": {"severity": "Critical", "title": "t"},
                                "CVE-2026-2": {"severity": "Important", "title": "t"}}}
    client = WindowsUpdateAgent()

    rows = await collect_host(db_session, agent, client, feed)

    assert client.calls == ["windows_update_facts"]
    assert sorted(r["cve"] for r in rows) == ["CVE-2026-1", "CVE-2026-2"]
    stored = (await db_session.scalars(select(HostCve).where(HostCve.agent_id == agent.id))).all()
    assert {(h.package, h.severity, h.distro) for h in stored} == {("KB5122882", "Critical", "windows"),
                                                                    ("KB5122882", "Important", "windows")}
    await db_session.execute(delete(HostCve).where(HostCve.agent_id == agent.id))
    await db_session.delete(agent)
    await db_session.commit()


async def test_the_fleet_view_ranks_and_counts_one_word_once_whatever_its_case(db_session):
    token, raw = await _make_api_token(db_session)
    with TestClient(create_app()) as client:       # the shared database holds real rows too: compare before/after
        before = client.get("/api/v1/security/summary", headers=_headers(raw)).json()["by_severity"].get("critical", 0)
    win = await _make_agent(db_session)
    rh = await _make_agent(db_session)
    db_session.add_all([
        HostCve(agent_id=win.id, cve="CVE-2026-1", package="KB5122882", fixed_version="KB5122882", severity="Critical", distro="windows"),
        HostCve(agent_id=rh.id, cve="CVE-2026-3", package="openssl", fixed_version="3.0.7-27", severity="critical", distro="redhat"),
        HostCve(agent_id=rh.id, cve="CVE-2026-4", package="bash", fixed_version="5.1-8", severity="moderate", distro="redhat"),
    ])
    await db_session.commit()
    with TestClient(create_app()) as client:
        summary = client.get("/api/v1/security/summary", headers=_headers(raw)).json()
        listed = client.get("/api/v1/security/cves", headers=_headers(raw)).json()
        crit = client.get("/api/v1/security/cves", params={"severity": "CRITICAL"}, headers=_headers(raw)).json()

    assert summary["by_severity"].get("critical") == before + 2 and "Critical" not in summary["by_severity"]
    mine = [c for c in (listed.get("cves") or listed.get("items") or []) if c["cve"] in ("CVE-2026-1", "CVE-2026-3", "CVE-2026-4")]
    assert [c["cve"] for c in mine][-1] == "CVE-2026-4"          # moderate ranks after both criticals
    assert {c["cve"] for c in (crit.get("cves") or crit.get("items") or [])} >= {"CVE-2026-1", "CVE-2026-3"}

    for a in (win, rh):
        await db_session.execute(delete(HostCve).where(HostCve.agent_id == a.id))
        await db_session.delete(a)
    await db_session.delete(token)
    await db_session.commit()


class Recorder:
    def __init__(self):
        self.calls = []

    async def call_tool(self, name, body):
        self.calls.append((name, body))
        return {"changed": False, "msg": "1 update(s) would be installed: KB5122882", "data": {}}


async def test_bulk_update_installs_the_kbs_that_close_the_hosts_cves_on_windows(db_session):
    from bossman.api.plans import get_client_factory

    win = await _make_agent(db_session, facts={"os_family": "windows"})
    empty = await _make_agent(db_session, facts={"os_family": "windows"})
    db_session.add_all([HostCve(agent_id=win.id, cve=f"CVE-2026-{i}", package="KB5122882", fixed_version="KB5122882",
                                severity="Critical", distro="windows") for i in (1, 2)])
    await db_session.commit()
    token, raw = await _make_api_token(db_session)
    rec = Recorder()
    app = create_app()
    app.dependency_overrides[get_client_factory] = lambda: (lambda agent, settings: rec)
    with TestClient(app) as client:
        out = client.post("/api/v1/security/bulk-update", json={"agent_ids": [str(win.id), str(empty.id)], "dry_run": True},
                          headers=_headers(raw)).json()

    by_host = {r["agent_id"]: r for r in out["results"]}
    assert rec.calls == [("windows_update", {"state": "installed", "category_names": ["*"], "reboot": "never",
                                             "dry_run": True, "accept_list": ["KB5122882"]})]
    assert by_host[str(win.id)]["status"] == "ok" and by_host[str(win.id)]["tool"] == "windows_update"
    assert by_host[str(empty.id)]["status"] == "nothing_to_do" and "closes a known CVE" in by_host[str(empty.id)]["reason"]

    await db_session.execute(delete(HostCve).where(HostCve.agent_id == win.id))
    for x in (win, empty, token):
        await db_session.delete(x)
    await db_session.commit()


async def test_an_incomplete_search_keeps_the_last_complete_state(db_session):
    agent = await _make_agent(db_session, facts={"os_family": "windows"})
    feed = CveFeed(_S())
    feed._msrc = {"KB5122882": {"CVE-2026-1": {"severity": "Critical", "title": "t"}}}
    await collect_host(db_session, agent, WindowsUpdateAgent(), feed)
    after_boot = WindowsUpdateAgent(search="SucceededWithErrors")      # +19 s after a reboot, measured
    await collect_host(db_session, agent, after_boot, feed)
    kept = (await db_session.scalars(select(HostCve).where(HostCve.agent_id == agent.id))).all()
    assert [h.cve for h in kept] == ["CVE-2026-1"]
    await db_session.execute(delete(HostCve).where(HostCve.agent_id == agent.id))
    await db_session.delete(agent)
    await db_session.commit()
