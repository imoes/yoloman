"""Block W2 — generative dashboard: spec parsing/validation + the persist/get
endpoints (AI generation itself is monkeypatched)."""

import uuid

import bossman.api.chat as chat_api
from bossman.main import create_app
from bossman.services.auth import new_api_token
from bossman.services.chat_dashboard import _clean_spec, _parse_specs, generate_dashboard

from fastapi.testclient import TestClient


def test_parse_specs_tolerates_fence_and_prose():
    text = 'Here is your dashboard:\n```json\n[{"widget_type":"donut","title":"X","data":{"buckets":[]}}]\n```\nDone.'
    specs = _parse_specs(text)
    assert len(specs) == 1 and specs[0]["widget_type"] == "donut"
    # bare array
    assert _parse_specs('[{"widget_type":"stat","data":{}}]')[0]["widget_type"] == "stat"
    # junk -> empty
    assert _parse_specs("no json here") == []


def test_clean_spec_validates_and_clamps():
    assert _clean_spec({"widget_type": "bogus"}) is None
    c = _clean_spec({"widget_type": "bar", "title": "T", "data": {"buckets": []}, "gs_w": 99, "gs_h": 1})
    assert c["widget_type"] == "bar" and c["gs_w"] == 12 and c["gs_h"] == 2  # 99->12 clamp, 1->2 clamp


class _DummyBackend:
    # not agentic (no complete_with_tools) -> generate_dashboard uses stream()
    async def stream(self, messages, **kw):
        yield {"type": "delta", "text": '[{"widget_type":"stat","title":"Hosts","data":{"value":36,"label":"enrolled"}}]'}


async def test_generate_dashboard_from_stream():
    async def executor(name, args):
        return {}

    widgets = await generate_dashboard(_DummyBackend(), executor, "overview")
    assert len(widgets) == 1 and widgets[0]["widget_type"] == "stat" and widgets[0]["data"]["value"] == 36


async def _make_api_token(db_session, name="dash-caller"):
    row, raw = new_api_token(name)
    db_session.add(row)
    await db_session.flush()
    await db_session.commit()
    return row, raw


async def test_generate_and_get_endpoint(db_session, monkeypatch):
    api_token, raw = await _make_api_token(db_session)

    async def fake_generate(backend, executor, prompt):
        return [{"widget_type": "donut", "title": "Deploy", "data": {"buckets": [{"key": "success", "count": 8}]}, "gs_w": 4, "gs_h": 4}]

    monkeypatch.setattr(chat_api, "generate_dashboard", fake_generate)
    # avoid building a real backend
    async def fake_build(settings, oauth, username, backend_name, model):
        return object()

    monkeypatch.setattr(chat_api, "_build_backend", fake_build)

    headers = {"Authorization": f"Bearer {raw}"}
    with TestClient(create_app()) as client:
        r = client.post("/api/v1/chat/dashboard/generate", json={"prompt": "show deploys", "backend": "hermes_web"}, headers=headers)
        assert r.status_code == 200, r.text
        assert r.json()["widgets"][0]["widget_type"] == "donut"
        # persisted -> GET returns it
        g = client.get("/api/v1/chat/dashboard", headers=headers)
        assert g.json()["widgets"][0]["title"] == "Deploy" and g.json()["prompt"] == "show deploys"

    # cleanup the row
    from sqlalchemy import delete
    from bossman.db.models import GeneratedDashboard

    await db_session.execute(delete(GeneratedDashboard).where(GeneratedDashboard.username == "dash-caller"))
    await db_session.delete(api_token)
    await db_session.commit()
