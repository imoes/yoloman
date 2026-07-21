"""Fleet-search: parser unit tests (pure) + end-to-end query tests through the
real app + Postgres (like tests/test_agents_api.py)."""

import uuid

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import delete

from bossman.db.models import AccessGrant, Agent, Service
from bossman.main import create_app
from bossman.services.auth import new_api_token
from bossman.services.search import And, Not, Or, Term, parse_query


# ── parser (no DB) ─────────────────────────────────────────────────────────


def test_parse_bare_word():
    assert parse_query("disk") == Term(None, "disk")


def test_parse_implicit_and_with_fields():
    assert parse_query("s:disk st:CRIT") == And((Term("service", "disk"), Term("state", "CRIT")))


def test_parse_or():
    assert parse_query("st:CRIT OR st:WARN") == Or((Term("state", "CRIT"), Term("state", "WARN")))
    assert parse_query("st:CRIT | st:WARN") == Or((Term("state", "CRIT"), Term("state", "WARN")))


def test_parse_not_bang():
    assert parse_query("s:postgres !host:db-old") == And(
        (Term("service", "postgres"), Not(Term("host", "db-old")))
    )


def test_parse_quotes():
    assert parse_query('s:"backup job"') == Term("service", "backup job")


def test_parse_parens_precedence():
    assert parse_query("(st:CRIT OR st:WARN) s:disk") == And(
        (Or((Term("state", "CRIT"), Term("state", "WARN"))), Term("service", "disk"))
    )


def test_parse_field_aliases():
    assert parse_query("h:web") == Term("host", "web")
    assert parse_query("crit:prod") == Term("criticality", "prod")
    assert parse_query("location:MUE-0") == Term("site", "MUE-0")


def test_parse_empty():
    assert parse_query("") is None
    assert parse_query("   ") is None


# ── end-to-end ─────────────────────────────────────────────────────────────


def _headers(raw):
    return {"Authorization": f"Bearer {raw}"}


@pytest.fixture
async def fixture_fleet(db_session):
    tag = uuid.uuid4().hex[:8]
    web = Agent(name=f"web01-{tag}", token="t", mode="standalone", enrollment_state="enrolled",
                criticality="prod", site="MUE-0", groups=["linux", "web"])
    db = Agent(name=f"db01-{tag}", token="t", mode="standalone", enrollment_state="enrolled",
               criticality="prod", site="FRA-1", groups=["linux", "db"])
    tst = Agent(name=f"test01-{tag}", token="t", mode="standalone", enrollment_state="enrolled",
                criticality="test", site="MUE-0", groups=["staging"])
    db_session.add_all([web, db, tst])
    await db_session.flush()
    svcs = [
        Service(agent_id=web.id, name=f"disk root {tag}", metric="disk", state="OK"),
        Service(agent_id=db.id, name=f"disk data {tag}", metric="disk", state="CRIT"),
        Service(agent_id=db.id, name=f"postgres conn {tag}", metric="pg", state="WARN"),
        Service(agent_id=tst.id, name=f"cpu load {tag}", metric="cpu", state="OK"),
    ]
    db_session.add_all(svcs)
    row, raw = new_api_token(f"search-caller-{tag}")
    db_session.add(row)
    db_session.add(AccessGrant(subject_kind="api_token", subject_ref=f"search-caller-{tag}", scope="all"))
    await db_session.commit()
    yield {"tag": tag, "web": web, "db": db, "tst": tst, "raw": raw, "token": row, "svcs": svcs}
    for s in svcs:
        await db_session.execute(delete(Service).where(Service.id == s.id))
    for a in (web, db, tst):
        await db_session.execute(delete(Agent).where(Agent.id == a.id))
    await db_session.execute(delete(AccessGrant).where(AccessGrant.subject_ref == f"search-caller-{tag}"))
    await db_session.delete(row)
    await db_session.commit()


async def test_search_services_bare_word(fixture_fleet):
    f = fixture_fleet
    app = create_app()
    with TestClient(app) as client:
        r = client.get("/api/v1/search/services", params={"q": f"disk {f['tag']}"}, headers=_headers(f["raw"]))
    assert r.status_code == 200
    names = {s["name"] for s in r.json()["services"]}
    assert names == {f"disk root {f['tag']}", f"disk data {f['tag']}"}


async def test_search_services_and_state(fixture_fleet):
    f = fixture_fleet
    app = create_app()
    with TestClient(app) as client:
        r = client.get("/api/v1/search/services", params={"q": f"s:disk st:CRIT {f['tag']}"}, headers=_headers(f["raw"]))
    svcs = r.json()["services"]
    assert len(svcs) == 1 and svcs[0]["state"] == "CRIT"


async def test_search_services_or(fixture_fleet):
    f = fixture_fleet
    app = create_app()
    with TestClient(app) as client:
        r = client.get("/api/v1/search/services", params={"q": f"(st:CRIT OR st:WARN) {f['tag']}"}, headers=_headers(f["raw"]))
    states = sorted(s["state"] for s in r.json()["services"])
    assert states == ["CRIT", "WARN"]


async def test_search_hosts_criticality_and_not_site(fixture_fleet):
    f = fixture_fleet
    app = create_app()
    with TestClient(app) as client:
        r = client.get("/api/v1/search/hosts", params={"q": f"crit:prod !site:FRA-1 {f['tag']}"}, headers=_headers(f["raw"]))
    names = {h["name"] for h in r.json()["hosts"]}
    assert names == {f"web01-{f['tag']}"}


async def test_search_hosts_group(fixture_fleet):
    f = fixture_fleet
    app = create_app()
    with TestClient(app) as client:
        r = client.get("/api/v1/search/hosts", params={"q": f"hg:linux {f['tag']}"}, headers=_headers(f["raw"]))
    names = {h["name"] for h in r.json()["hosts"]}
    assert names == {f"web01-{f['tag']}", f"db01-{f['tag']}"}


async def test_search_hosts_state_rollup(fixture_fleet):
    f = fixture_fleet
    app = create_app()
    with TestClient(app) as client:
        r = client.get("/api/v1/search/hosts", params={"q": f"h:db01-{f['tag']}"}, headers=_headers(f["raw"]))
    hosts = r.json()["hosts"]
    assert len(hosts) == 1 and hosts[0]["state_rollup"] == "CRIT"


async def test_unified_search_groups_by_type(fixture_fleet):
    f = fixture_fleet
    app = create_app()
    with TestClient(app) as client:
        r = client.get("/api/v1/search", params={"q": f["tag"]}, headers=_headers(f["raw"]))
    body = r.json()
    assert body["counts"]["service"] >= 1
    assert body["counts"]["host"] >= 1


async def test_bulk_assign_facets(fixture_fleet):
    f = fixture_fleet
    app = create_app()
    with TestClient(app) as client:
        r = client.post(
            "/api/v1/agents/mass-update/facets",
            json={"agent_ids": [str(f["tst"].id)], "criticality": "stage", "site": "BER-1",
                  "add_tags": {"env": "qa"}},
            headers=_headers(f["raw"]),
        )
        assert r.status_code == 200, r.text
        # The tst host is now stage + BER-1 + env:qa → findable by all three.
        hosts = client.get("/api/v1/search/hosts", params={"q": f"crit:stage site:BER-1 tag:env:qa {f['tag']}"},
                           headers=_headers(f["raw"])).json()["hosts"]
    assert {h["name"] for h in hosts} == {f"test01-{f['tag']}"}
    assert hosts[0]["criticality"] == "stage" and hosts[0]["site"] == "BER-1"


async def test_bulk_assign_clear(fixture_fleet):
    f = fixture_fleet
    app = create_app()
    with TestClient(app) as client:
        r = client.post(
            "/api/v1/agents/mass-update/facets",
            json={"agent_ids": [str(f["web"].id)], "criticality": ""},  # clear
            headers=_headers(f["raw"]),
        )
        assert r.status_code == 200, r.text
        assert r.json()[0]["criticality"] is None


async def test_bulk_assign_rejects_bad_criticality(fixture_fleet):
    f = fixture_fleet
    app = create_app()
    with TestClient(app) as client:
        r = client.post("/api/v1/agents/mass-update/facets",
                        json={"agent_ids": [str(f["web"].id)], "criticality": "bogus"},
                        headers=_headers(f["raw"]))
    assert r.status_code == 422


async def test_distinct_sites_and_tags(fixture_fleet):
    f = fixture_fleet
    app = create_app()
    with TestClient(app) as client:
        sites = client.get("/api/v1/sites", headers=_headers(f["raw"])).json()["sites"]
        tags = client.get("/api/v1/tags", headers=_headers(f["raw"])).json()["tags"]
    assert "MUE-0" in sites and "FRA-1" in sites
