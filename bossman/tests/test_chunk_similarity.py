"""Real, DB-backed tests for bossman.services.chunk_similarity — see
tests/conftest.py's db_session fixture. index_chunk/find_similar_chunks
both commit internally (same reason plan_engine.run_plan's own tests need
explicit cleanup rather than relying on db_session's trailing rollback:
a commit makes the write durable regardless of what happens after it), so
every test here deletes its own chunk_embeddings rows afterward.

FakeEmbeddingClient returns deterministic, hand-picked vectors instead of
calling a real network endpoint — the real bge-m3 endpoint is exercised
separately (see docs/plan.md's "Chunk-similarity embedding cache" section
for that real, non-mocked run).
"""

from bossman.db.models import CHUNK_EMBEDDING_DIM, ChunkEmbedding
from bossman.services.chunk_similarity import find_similar_chunks, index_chunk


def _vec(*components: float) -> list[float]:
    """Pads a short, human-readable direction (e.g. (1.0, 0.0)) out to the
    real chunk_embeddings.embedding column's fixed width — cosine
    similarity between two such padded vectors depends only on the given
    components, since every padded dimension is 0 in both."""
    padded = list(components) + [0.0] * (CHUNK_EMBEDDING_DIM - len(components))
    return padded[:CHUNK_EMBEDDING_DIM]


class FakeEmbeddingClient:
    """Maps exact input text to a pre-registered vector — lets a test
    control similarity precisely instead of depending on a real model's
    actual semantics."""

    def __init__(self, model="fake-model"):
        self.model = model
        self.vectors: dict[str, list[float]] = {}
        self.embed_calls: list[list[str]] = []

    def register(self, text: str, vector: list[float]) -> None:
        self.vectors[text] = vector

    async def embed(self, texts: list[str]) -> list[list[float]]:
        self.embed_calls.append(list(texts))
        return [self.vectors[t] for t in texts]


async def _cleanup(db_session, *chunk_ids):
    for chunk_id in chunk_ids:
        row = await db_session.get(ChunkEmbedding, chunk_id)
        if row is not None:
            await db_session.delete(row)
    await db_session.commit()


async def test_index_chunk_embeds_and_persists(db_session):
    client = FakeEmbeddingClient()
    client.register("apt install docker-ce", _vec(1.0, 0.0))

    indexed = await index_chunk(
        db_session,
        client,
        plan_name="img_docker",
        chunk_name="debian_packages",
        chunk_id="chunk-abc",
        source_hash="src-hash-1",
        source_text="apt install docker-ce",
    )

    assert indexed is True
    assert client.embed_calls == [["apt install docker-ce"]]

    row = await db_session.get(ChunkEmbedding, "chunk-abc")
    assert row is not None
    assert row.plan_name == "img_docker"
    assert row.chunk_name == "debian_packages"
    assert row.source_hash == "src-hash-1"
    assert row.model == "fake-model"

    await _cleanup(db_session, "chunk-abc")


async def test_index_chunk_exact_hit_skips_embedding_call(db_session):
    client = FakeEmbeddingClient()
    client.register("apt install docker-ce", _vec(1.0, 0.0))

    first = await index_chunk(
        db_session,
        client,
        plan_name="img_docker",
        chunk_name="debian_packages",
        chunk_id="chunk-abc",
        source_hash="src-hash-1",
        source_text="apt install docker-ce",
    )
    assert first is True
    assert len(client.embed_calls) == 1

    # Same chunk_id, same model — the cache hit this whole cache exists
    # for: no second embed() call at all, not just a cheap re-embed.
    second = await index_chunk(
        db_session,
        client,
        plan_name="img_docker",
        chunk_name="debian_packages",
        chunk_id="chunk-abc",
        source_hash="src-hash-1",
        source_text="apt install docker-ce",
    )
    assert second is False
    assert len(client.embed_calls) == 1

    await _cleanup(db_session, "chunk-abc")


async def test_index_chunk_different_model_reembeds(db_session):
    client_a = FakeEmbeddingClient(model="model-a")
    client_a.register("apt install docker-ce", _vec(1.0, 0.0))
    client_b = FakeEmbeddingClient(model="model-b")
    client_b.register("apt install docker-ce", _vec(0.0, 1.0))

    await index_chunk(
        db_session, client_a, plan_name="p", chunk_name="c", chunk_id="chunk-xyz",
        source_hash=None, source_text="apt install docker-ce",
    )
    indexed_again = await index_chunk(
        db_session, client_b, plan_name="p", chunk_name="c", chunk_id="chunk-xyz",
        source_hash=None, source_text="apt install docker-ce",
    )

    # Same chunk_id but a different model is not the same cache entry —
    # chunk_id is the primary key, so this upserts in place; the important
    # behavioral proof is that it DID re-embed (True), not skip.
    assert indexed_again is True

    await _cleanup(db_session, "chunk-xyz")


async def test_find_similar_chunks_returns_close_match_above_threshold(db_session):
    client = FakeEmbeddingClient()
    client.register("apt install docker-ce docker-ce-cli containerd.io", _vec(1.0, 0.0))
    client.register("install docker-ce and containerd via apt", _vec(0.99, 0.01))  # near-identical direction

    await index_chunk(
        db_session, client, plan_name="img_docker", chunk_name="debian_packages", chunk_id="chunk-close",
        source_hash="h1", source_text="apt install docker-ce docker-ce-cli containerd.io",
    )

    results = await find_similar_chunks(
        db_session, client, source_text="install docker-ce and containerd via apt", top_k=3, threshold=0.9
    )

    assert len(results) == 1
    assert results[0].chunk_id == "chunk-close"
    assert results[0].plan_name == "img_docker"
    assert results[0].similarity > 0.9

    await _cleanup(db_session, "chunk-close")


async def test_find_similar_chunks_excludes_unrelated_below_threshold(db_session):
    client = FakeEmbeddingClient()
    client.register("apt install docker-ce", _vec(1.0, 0.0))
    client.register("configure nginx virtual host", _vec(0.0, 0.0, 0.0, 1.0))  # orthogonal -> similarity 0

    await index_chunk(
        db_session, client, plan_name="img_docker", chunk_name="debian_packages", chunk_id="chunk-far",
        source_hash="h1", source_text="apt install docker-ce",
    )

    results = await find_similar_chunks(
        db_session, client, source_text="configure nginx virtual host", top_k=3, threshold=0.85
    )

    assert results == []

    await _cleanup(db_session, "chunk-far")


async def test_find_similar_chunks_sorts_by_similarity_descending(db_session):
    client = FakeEmbeddingClient()
    client.register("query", _vec(1.0, 0.0))
    client.register("somewhat close", _vec(0.9, 0.1))
    client.register("very close", _vec(0.99, 0.0, 0.0, 0.01))

    await index_chunk(
        db_session, client, plan_name="p", chunk_name="a", chunk_id="chunk-somewhat",
        source_hash=None, source_text="somewhat close",
    )
    await index_chunk(
        db_session, client, plan_name="p", chunk_name="b", chunk_id="chunk-very",
        source_hash=None, source_text="very close",
    )

    results = await find_similar_chunks(db_session, client, source_text="query", top_k=5, threshold=0.0)

    assert [r.chunk_id for r in results] == ["chunk-very", "chunk-somewhat"]
    assert results[0].similarity > results[1].similarity

    await _cleanup(db_session, "chunk-somewhat", "chunk-very")


async def test_find_similar_chunks_respects_top_k(db_session):
    client = FakeEmbeddingClient()
    client.register("query", _vec(1.0, 0.0))
    for i in range(5):
        client.register(f"match {i}", _vec(1.0 - i * 0.001, 0.0))
        await index_chunk(
            db_session, client, plan_name="p", chunk_name=f"c{i}", chunk_id=f"chunk-topk-{i}",
            source_hash=None, source_text=f"match {i}",
        )

    results = await find_similar_chunks(db_session, client, source_text="query", top_k=2, threshold=0.0)

    assert len(results) == 2

    await _cleanup(db_session, *[f"chunk-topk-{i}" for i in range(5)])


async def test_find_similar_chunks_ignores_rows_from_a_different_model(db_session):
    other_model_client = FakeEmbeddingClient(model="other-model")
    other_model_client.register("apt install docker-ce", _vec(1.0, 0.0))
    await index_chunk(
        db_session, other_model_client, plan_name="p", chunk_name="c", chunk_id="chunk-other-model",
        source_hash=None, source_text="apt install docker-ce",
    )

    current_client = FakeEmbeddingClient(model="current-model")
    current_client.register("query", _vec(1.0, 0.0))

    results = await find_similar_chunks(db_session, current_client, source_text="query", top_k=5, threshold=0.0)

    assert results == []

    await _cleanup(db_session, "chunk-other-model")
