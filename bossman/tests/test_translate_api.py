"""End-to-end tests for /api/v1/translate through the real FastAPI app and
real database (see tests/conftest.py's db_session fixture). Fake
embedding/chat clients are injected via app.dependency_overrides, the
same test seam pattern the plans/chunks routes already use.
"""

from fastapi.testclient import TestClient

from bossman.api.chunks import get_embedding_client
from bossman.api.translate import get_chat_client
from bossman.db.models import ChunkEmbedding
from bossman.main import create_app
from bossman.services.auth import new_api_token


class FakeEmbeddingClient:
    model = "fake-model"

    def __init__(self):
        self.vectors: dict[str, list[float]] = {}

    def register(self, text: str, vector: list[float]) -> None:
        self.vectors[text] = vector

    async def embed(self, texts: list[str]) -> list[list[float]]:
        return [self.vectors[t] for t in texts]


class FakeChatClient:
    def __init__(self, responses=None):
        self._responses = responses or []
        self.calls = 0

    async def complete_json(self, messages, json_schema, schema_name, **_):
        response = self._responses[self.calls]
        self.calls += 1
        return response


def _vec(*components: float, dim: int = 1024) -> list[float]:
    padded = list(components) + [0.0] * (dim - len(components))
    return padded[:dim]


async def _make_api_token(db_session):
    row, raw = new_api_token("translate-caller")
    db_session.add(row)
    await db_session.flush()
    await db_session.commit()
    return row, raw


def _headers(raw):
    return {"Authorization": f"Bearer {raw}"}


VALID_LLM_OUTPUT = {
    "steps": [
        {"name": "install_ca_certs", "module": "apt", "params": {"name": ["ca-certificates"], "state": "present"}}
    ]
}


async def test_translate_requires_auth(db_session):
    app = create_app()
    app.dependency_overrides[get_embedding_client] = lambda: FakeEmbeddingClient()
    app.dependency_overrides[get_chat_client] = lambda: FakeChatClient()

    with TestClient(app) as client:
        resp = client.post(
            "/api/v1/translate",
            json={"plan_name": "p", "chunk_name": "c", "source_text": "apt install ca-certificates"},
        )

    assert resp.status_code == 401


async def test_translate_success_calls_llm_and_persists(db_session):
    api_token, raw = await _make_api_token(db_session)
    app = create_app()
    fake_embed = FakeEmbeddingClient()
    fake_embed.register("apt install ca-certificates", _vec(1.0, 0.0))
    app.dependency_overrides[get_embedding_client] = lambda: fake_embed
    app.dependency_overrides[get_chat_client] = lambda: FakeChatClient(responses=[VALID_LLM_OUTPUT])

    with TestClient(app) as client:
        resp = client.post(
            "/api/v1/translate",
            json={"plan_name": "p", "chunk_name": "install_certs", "source_text": "apt install ca-certificates"},
            headers=_headers(raw),
        )

    assert resp.status_code == 200
    body = resp.json()
    assert body["source"] == "llm"
    assert body["attempts"] == 1
    assert body["similar_chunk_id"] is None
    assert body["chunk"]["steps"][0]["module"] == "apt"
    assert body["chunk"]["steps"][0]["params"] == {"name": ["ca-certificates"], "state": "present"}

    from bossman.services.plan_loader import Chunk, PlanStep

    # Step name comes from the LLM's own output ("install_ca_certs" in
    # VALID_LLM_OUTPUT), not the chunk_name request field — chunk_id is
    # content-addressed over the full step, including its own name.
    step = PlanStep(
        name="install_ca_certs", kind="module", module="apt", body={"name": ["ca-certificates"], "state": "present"}
    )
    chunk_id = Chunk(name="install_certs", steps=[step]).chunk_id
    row = await db_session.get(ChunkEmbedding, chunk_id)
    assert row is not None

    await db_session.delete(row)
    await db_session.delete(api_token)
    await db_session.commit()


async def test_translate_returns_422_after_exhausted_retries(db_session):
    api_token, raw = await _make_api_token(db_session)
    app = create_app()
    fake_embed = FakeEmbeddingClient()
    fake_embed.register("apt install ca-certificates", _vec(1.0, 0.0))
    app.dependency_overrides[get_embedding_client] = lambda: fake_embed
    app.dependency_overrides[get_chat_client] = lambda: FakeChatClient(
        responses=[{"steps": []}, {"steps": []}, {"steps": []}]
    )

    with TestClient(app) as client:
        resp = client.post(
            "/api/v1/translate",
            json={
                "plan_name": "p",
                "chunk_name": "install_certs",
                "source_text": "apt install ca-certificates",
                "max_retries": 2,
            },
            headers=_headers(raw),
        )

    assert resp.status_code == 422
    assert "non-empty" in resp.json()["detail"]

    await db_session.delete(api_token)
    await db_session.commit()
