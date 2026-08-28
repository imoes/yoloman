"""Tests for the OU move endpoint (Block L3e drag-and-drop backend) —
reparenting an OU rewrites the materialized path + ltree_path of the whole
subtree and rejects a cycle. Real HTTP + real Postgres (db_session fixture).
"""

import uuid
from tests.naming import owned_name, run_suffix

from fastapi.testclient import TestClient
from sqlalchemy import text

from bossman.main import create_app
from bossman.services.auth import new_api_token


async def _api_token(db_session):
    row, raw = new_api_token(owned_name("ou-test"))
    db_session.add(row)
    await db_session.commit()
    return row, raw


def _h(raw):
    return {"Authorization": f"Bearer {raw}"}


async def _cleanup_ous(db_session, *names_like):
    for like in names_like:
        await db_session.execute(text("DELETE FROM ou_nodes WHERE name LIKE :p"), {"p": like})
    await db_session.commit()


async def test_move_ou_rewrites_subtree_paths(db_session):
    _tok, raw = await _api_token(db_session)
    sfx = run_suffix()
    with TestClient(create_app()) as client:
        a = client.post("/api/v1/ou", json={"name": f"A-{sfx}"}, headers=_h(raw)).json()
        b = client.post("/api/v1/ou", json={"name": f"B-{sfx}", "parent_id": a["id"]}, headers=_h(raw)).json()
        client.post("/api/v1/ou", json={"name": f"C-{sfx}", "parent_id": b["id"]}, headers=_h(raw))
        dst = client.post("/api/v1/ou", json={"name": f"D-{sfx}"}, headers=_h(raw)).json()

        # Move B (and its child C) from under A to under D.
        resp = client.post(f"/api/v1/ou/{b['id']}/move", json={"parent_id": dst["id"]}, headers=_h(raw))
        assert resp.status_code == 200

        nodes = {n["name"]: n for n in client.get("/api/v1/ou", headers=_h(raw)).json()}
        assert nodes[f"B-{sfx}"]["parent_id"] == dst["id"]
        assert nodes[f"B-{sfx}"]["path"] == f"/D-{sfx}/B-{sfx}"
        assert nodes[f"C-{sfx}"]["path"] == f"/D-{sfx}/B-{sfx}/C-{sfx}"
        # ltree_path rewritten too (dots, sanitized labels).
        assert nodes[f"C-{sfx}"]["ltree_path"] == f"D-{sfx}.B-{sfx}.C-{sfx}"

    await _cleanup_ous(db_session, f"%-{sfx}")


async def test_move_into_own_subtree_rejected(db_session):
    _tok, raw = await _api_token(db_session)
    sfx = run_suffix()
    with TestClient(create_app()) as client:
        a = client.post("/api/v1/ou", json={"name": f"A-{sfx}"}, headers=_h(raw)).json()
        b = client.post("/api/v1/ou", json={"name": f"B-{sfx}", "parent_id": a["id"]}, headers=_h(raw)).json()
        # Moving A under its own descendant B would create a cycle.
        resp = client.post(f"/api/v1/ou/{a['id']}/move", json={"parent_id": b["id"]}, headers=_h(raw))
        assert resp.status_code == 422

    await _cleanup_ous(db_session, f"%-{sfx}")


async def test_move_to_root(db_session):
    _tok, raw = await _api_token(db_session)
    sfx = run_suffix()
    with TestClient(create_app()) as client:
        a = client.post("/api/v1/ou", json={"name": f"A-{sfx}"}, headers=_h(raw)).json()
        b = client.post("/api/v1/ou", json={"name": f"B-{sfx}", "parent_id": a["id"]}, headers=_h(raw)).json()
        resp = client.post(f"/api/v1/ou/{b['id']}/move", json={"parent_id": None}, headers=_h(raw))
        assert resp.status_code == 200

        nodes = {n["name"]: n for n in client.get("/api/v1/ou", headers=_h(raw)).json()}
        assert nodes[f"B-{sfx}"]["parent_id"] is None
        assert nodes[f"B-{sfx}"]["path"] == f"/B-{sfx}"
        assert nodes[f"B-{sfx}"]["ltree_path"] == f"B-{sfx}"

    await _cleanup_ous(db_session, f"%-{sfx}")
