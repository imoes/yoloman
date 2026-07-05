"""Real, DB-backed tests for bossman.services.plan_search — see
tests/conftest.py's db_session fixture. index_plan_catalog commits
internally (same reason chunk_similarity's own tests need explicit
cleanup rather than relying on db_session's trailing rollback), so every
test here deletes its own plan_embeddings rows afterward.
"""

from pathlib import Path

from bossman.db.models import PlanEmbedding
from bossman.services.plan_loader import parse_plan
from bossman.services.plan_search import index_plan_catalog, search_plans


def _vec(*components: float, dim: int = 1024) -> list[float]:
    padded = list(components) + [0.0] * (dim - len(components))
    return padded[:dim]


class FakeEmbeddingClient:
    def __init__(self, model="fake-model"):
        self.model = model
        self.vectors: dict[str, list[float]] = {}
        self.embed_calls: list[list[str]] = []

    def register(self, text: str, vector: list[float]) -> None:
        self.vectors[text] = vector

    async def embed(self, texts: list[str]) -> list[list[float]]:
        self.embed_calls.append(list(texts))
        return [self.vectors[t] for t in texts]


def _plan(name, description):
    text = f"name: {name}\ndescription: {description!r}\nsteps:\n  - name: s\n    ansible.builtin.copy: {{dest: /tmp/x}}\n"
    return parse_plan(text.encode(), Path(f"{name}.yaml"))


async def _cleanup(db_session, *names):
    for name in names:
        row = await db_session.get(PlanEmbedding, name)
        if row is not None:
            await db_session.delete(row)
    await db_session.commit()


async def test_index_plan_catalog_embeds_and_persists(db_session):
    plan = _plan("img_docker", "Installs Docker CE")
    client = FakeEmbeddingClient()
    client.register("img_docker: Installs Docker CE", _vec(1.0, 0.0))

    count = await index_plan_catalog(db_session, client, [plan])

    assert count == 1
    row = await db_session.get(PlanEmbedding, "img_docker")
    assert row is not None
    assert row.description == "Installs Docker CE"
    assert row.model == "fake-model"

    await _cleanup(db_session, "img_docker")


async def test_index_plan_catalog_short_circuits_unchanged_plans(db_session):
    plan = _plan("img_docker", "Installs Docker CE")
    client = FakeEmbeddingClient()
    client.register("img_docker: Installs Docker CE", _vec(1.0, 0.0))

    first = await index_plan_catalog(db_session, client, [plan])
    assert first == 1
    assert len(client.embed_calls) == 1

    second = await index_plan_catalog(db_session, client, [plan])
    assert second == 0
    assert len(client.embed_calls) == 1  # no second embed() call at all

    await _cleanup(db_session, "img_docker")


async def test_index_plan_catalog_batches_only_changed_plans(db_session):
    unchanged = _plan("plan_a", "first plan")
    changed = _plan("plan_b", "second plan")
    client = FakeEmbeddingClient()
    client.register("plan_a: first plan", _vec(1.0, 0.0))
    client.register("plan_b: second plan", _vec(0.0, 1.0))
    client.register("plan_b: second plan, revised", _vec(0.0, 0.9))

    await index_plan_catalog(db_session, client, [unchanged, changed])
    assert len(client.embed_calls) == 1
    assert set(client.embed_calls[0]) == {"plan_a: first plan", "plan_b: second plan"}

    revised = _plan("plan_b", "second plan, revised")
    count = await index_plan_catalog(db_session, client, [unchanged, revised])

    assert count == 1  # only plan_b re-embedded
    assert client.embed_calls[-1] == ["plan_b: second plan, revised"]
    row = await db_session.get(PlanEmbedding, "plan_b")
    assert row.description == "second plan, revised"

    await _cleanup(db_session, "plan_a", "plan_b")


async def test_search_plans_finds_close_match_above_threshold(db_session):
    plan = _plan("img_docker", "Installs Docker CE")
    client = FakeEmbeddingClient()
    client.register("img_docker: Installs Docker CE", _vec(1.0, 0.0))
    client.register("install docker", _vec(0.99, 0.01))

    await index_plan_catalog(db_session, client, [plan])
    results = await search_plans(db_session, client, query="install docker", top_k=5, threshold=0.75)

    assert len(results) == 1
    assert results[0].name == "img_docker"
    assert results[0].similarity > 0.75

    await _cleanup(db_session, "img_docker")


async def test_search_plans_excludes_below_threshold(db_session):
    plan = _plan("img_docker", "Installs Docker CE")
    client = FakeEmbeddingClient()
    client.register("img_docker: Installs Docker CE", _vec(1.0, 0.0))
    client.register("configure nginx", _vec(0.0, 0.0, 0.0, 1.0))

    await index_plan_catalog(db_session, client, [plan])
    results = await search_plans(db_session, client, query="configure nginx", top_k=5, threshold=0.75)

    assert results == []

    await _cleanup(db_session, "img_docker")


async def test_search_plans_ignores_rows_from_a_different_model(db_session):
    plan = _plan("img_docker", "Installs Docker CE")
    other_model_client = FakeEmbeddingClient(model="other-model")
    other_model_client.register("img_docker: Installs Docker CE", _vec(1.0, 0.0))
    await index_plan_catalog(db_session, other_model_client, [plan])

    current_client = FakeEmbeddingClient(model="current-model")
    current_client.register("install docker", _vec(1.0, 0.0))

    results = await search_plans(db_session, current_client, query="install docker", top_k=5, threshold=0.0)

    assert results == []

    await _cleanup(db_session, "img_docker")
