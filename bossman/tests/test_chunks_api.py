"""End-to-end tests for /api/v1/chunks/* through the real FastAPI app and
real database (see tests/conftest.py's db_session fixture). A FakeEmbeddingClient
is injected via app.dependency_overrides on get_embedding_client — the same
test seam pattern get_client_factory already uses for the plan-run route.
"""

from fastapi.testclient import TestClient

from bossman.api.chunks import get_embedding_client
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


def _vec(*components: float, dim: int = 1024) -> list[float]:
    padded = list(components) + [0.0] * (dim - len(components))
    return padded[:dim]


async def _make_api_token(db_session):
    row, raw = new_api_token("chunks-caller")
    db_session.add(row)
    await db_session.flush()
    await db_session.commit()
    return row, raw


def _headers(raw):
    return {"Authorization": f"Bearer {raw}"}


async def _cleanup(db_session, api_token, *chunk_ids):
    for chunk_id in chunk_ids:
        row = await db_session.get(ChunkEmbedding, chunk_id)
        if row is not None:
            await db_session.delete(row)
    await db_session.delete(api_token)
    await db_session.commit()


async def test_chunks_index_requires_auth(db_session):
    app = create_app()
    fake = FakeEmbeddingClient()
    app.dependency_overrides[get_embedding_client] = lambda: fake

    with TestClient(app) as client:
        resp = client.post(
            "/api/v1/chunks/index",
            json={"plan_name": "p", "chunk_name": "c", "chunk_id": "x", "source_text": "text"},
        )

    assert resp.status_code == 401


async def test_chunks_similar_requires_auth(db_session):
    app = create_app()
    fake = FakeEmbeddingClient()
    app.dependency_overrides[get_embedding_client] = lambda: fake

    with TestClient(app) as client:
        resp = client.post("/api/v1/chunks/similar", json={"source_text": "text"})

    assert resp.status_code == 401


async def test_index_then_find_similar_round_trip(db_session):
    api_token, raw = await _make_api_token(db_session)
    app = create_app()
    fake = FakeEmbeddingClient()
    fake.register("apt install docker-ce", _vec(1.0, 0.0))
    fake.register("install docker-ce via apt", _vec(0.99, 0.01))
    app.dependency_overrides[get_embedding_client] = lambda: fake

    with TestClient(app) as client:
        index_resp = client.post(
            "/api/v1/chunks/index",
            json={
                "plan_name": "img_docker",
                "chunk_name": "debian_packages",
                "chunk_id": "chunk-api-1",
                "source_hash": "hash-1",
                "source_text": "apt install docker-ce",
            },
            headers=_headers(raw),
        )
        assert index_resp.status_code == 200
        assert index_resp.json() == {"indexed": True, "chunk_id": "chunk-api-1"}

        # Second index of the exact same chunk_id is the cache hit.
        index_again = client.post(
            "/api/v1/chunks/index",
            json={
                "plan_name": "img_docker",
                "chunk_name": "debian_packages",
                "chunk_id": "chunk-api-1",
                "source_hash": "hash-1",
                "source_text": "apt install docker-ce",
            },
            headers=_headers(raw),
        )
        assert index_again.json() == {"indexed": False, "chunk_id": "chunk-api-1"}

        similar_resp = client.post(
            "/api/v1/chunks/similar",
            json={"source_text": "install docker-ce via apt", "top_k": 3, "threshold": 0.9},
            headers=_headers(raw),
        )

    assert similar_resp.status_code == 200
    candidates = similar_resp.json()["candidates"]
    assert len(candidates) == 1
    assert candidates[0]["chunk_id"] == "chunk-api-1"
    assert candidates[0]["plan_name"] == "img_docker"
    assert candidates[0]["similarity"] > 0.9

    await _cleanup(db_session, api_token, "chunk-api-1")


async def test_similar_defaults_to_configured_threshold(db_session):
    api_token, raw = await _make_api_token(db_session)
    app = create_app()
    fake = FakeEmbeddingClient()
    fake.register("apt install docker-ce", _vec(1.0, 0.0))
    fake.register("configure nginx", _vec(0.0, 0.0, 0.0, 1.0))
    app.dependency_overrides[get_embedding_client] = lambda: fake

    with TestClient(app) as client:
        client.post(
            "/api/v1/chunks/index",
            json={
                "plan_name": "p",
                "chunk_name": "c",
                "chunk_id": "chunk-api-2",
                "source_text": "apt install docker-ce",
            },
            headers=_headers(raw),
        )
        # No explicit threshold — relies on Settings.chunk_similarity_threshold
        # (0.85 default), which an orthogonal vector falls well below.
        resp = client.post(
            "/api/v1/chunks/similar",
            json={"source_text": "configure nginx"},
            headers=_headers(raw),
        )

    assert resp.json()["candidates"] == []

    await _cleanup(db_session, api_token, "chunk-api-2")
