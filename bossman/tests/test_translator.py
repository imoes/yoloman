"""Real, DB-backed tests for bossman.services.translator — see
tests/conftest.py's db_session fixture. translate_chunk commits internally
(via index_chunk, same reason chunk_similarity's own tests need explicit
cleanup), so every test here deletes its own chunk_embeddings rows
afterward. FakeEmbeddingClient/FakeChatClient are deterministic stand-ins
— the real end-to-end run against the actual qwen79b/bge-m3 endpoints is
documented in docs/plan.md's "real LLM translator" section.
"""

import json

import pytest

from bossman.db.models import ChunkEmbedding
from bossman.services.chat_client import ChatClientError
from bossman.services.translator import TranslationError, translate_chunk


def _vec(*components: float, dim: int = 1024) -> list[float]:
    padded = list(components) + [0.0] * (dim - len(components))
    return padded[:dim]


class FakeEmbeddingClient:
    def __init__(self, model="fake-model"):
        self.model = model
        self.vectors: dict[str, list[float]] = {}

    def register(self, text: str, vector: list[float]) -> None:
        self.vectors[text] = vector

    async def embed(self, texts: list[str]) -> list[list[float]]:
        return [self.vectors[t] for t in texts]


class FakeChatClient:
    def __init__(self, responses=None, error=None):
        self._responses = responses or []
        self._error = error
        self.calls: list[list[dict]] = []

    async def complete_json(self, messages, json_schema, schema_name, max_tokens=4000):
        self.calls.append(messages)
        if self._error:
            raise self._error
        return self._responses[len(self.calls) - 1]


VALID_LLM_OUTPUT = {
    "steps": [
        {"name": "install_ca_certs", "module": "apt", "params": {"name": ["ca-certificates"], "state": "present"}}
    ]
}


async def _cleanup(session, *chunk_ids):
    for chunk_id in chunk_ids:
        row = await session.get(ChunkEmbedding, chunk_id)
        if row is not None:
            await session.delete(row)
    await session.commit()


async def test_translate_chunk_calls_llm_when_no_similar_chunk_exists(db_session):
    embedding_client = FakeEmbeddingClient()
    embedding_client.register("apt install ca-certificates", _vec(1.0, 0.0))
    chat_client = FakeChatClient(responses=[VALID_LLM_OUTPUT])

    result = await translate_chunk(
        db_session, embedding_client, chat_client,
        plan_name="test_plan", chunk_name="install_certs", source_text="apt install ca-certificates",
        similarity_threshold=0.85,
    )

    assert result.source == "llm"
    assert result.attempts == 1
    assert result.similar_chunk_id is None
    assert len(chat_client.calls) == 1
    assert result.chunk.steps[0].module == "apt"
    assert result.chunk.steps[0].body == {"name": ["ca-certificates"], "state": "present"}

    # Persisted for future reuse.
    row = await db_session.get(ChunkEmbedding, result.chunk.chunk_id)
    assert row is not None
    assert row.translated_json is not None
    assert row.plan_name == "test_plan"

    await _cleanup(db_session, result.chunk.chunk_id)


async def test_translate_chunk_reuses_when_similar_translated_chunk_exists(db_session):
    from bossman.services.chunk_similarity import index_chunk

    embedding_client = FakeEmbeddingClient()
    embedding_client.register("apt install ca-certificates docker-ce", _vec(1.0, 0.0))
    embedding_client.register("apt install docker-ce and ca-certificates", _vec(0.99, 0.01))

    translated = json.dumps(
        {"os_family": None, "steps": [{"name": "s", "apt": {"name": ["docker-ce"], "state": "present"}}]}
    )
    await index_chunk(
        db_session, embedding_client,
        plan_name="existing_plan", chunk_name="existing_chunk", chunk_id="chunk-existing",
        source_hash="h1", source_text="apt install ca-certificates docker-ce",
        translated_json=translated,
    )

    chat_client = FakeChatClient(error=AssertionError("the LLM must not be called on a reuse hit"))

    result = await translate_chunk(
        db_session, embedding_client, chat_client,
        plan_name="new_plan", chunk_name="new_chunk", source_text="apt install docker-ce and ca-certificates",
        similarity_threshold=0.85,
    )

    assert result.source == "reused"
    assert result.similar_chunk_id == "chunk-existing"
    assert result.attempts == 0
    assert chat_client.calls == []
    assert result.chunk.steps[0].module == "apt"
    assert result.chunk.steps[0].body == {"name": ["docker-ce"], "state": "present"}

    await _cleanup(db_session, "chunk-existing")


async def test_translate_chunk_retries_on_invalid_output_then_succeeds(db_session):
    embedding_client = FakeEmbeddingClient()
    embedding_client.register("apt install ca-certificates", _vec(1.0, 0.0))
    # First response violates parse_plan's "'steps' must be a non-empty
    # list" rule (schema-valid JSON that our own reshaping/parse_plan
    # still rejects) — a real retry trigger, not a contrived one.
    chat_client = FakeChatClient(responses=[{"steps": []}, VALID_LLM_OUTPUT])

    result = await translate_chunk(
        db_session, embedding_client, chat_client,
        plan_name="test_plan", chunk_name="install_certs", source_text="apt install ca-certificates",
        similarity_threshold=0.85, max_retries=2,
    )

    assert result.source == "llm"
    assert result.attempts == 2
    assert len(chat_client.calls) == 2
    # The retry's message history carries the invalid output + the error feedback.
    assert len(chat_client.calls[1]) == 4  # system, user, assistant(invalid), user(feedback)
    assert "invalid" in chat_client.calls[1][-1]["content"].lower()

    await _cleanup(db_session, result.chunk.chunk_id)


async def test_translate_chunk_raises_after_exhausting_retries(db_session):
    embedding_client = FakeEmbeddingClient()
    embedding_client.register("apt install ca-certificates", _vec(1.0, 0.0))
    chat_client = FakeChatClient(responses=[{"steps": []}, {"steps": []}, {"steps": []}])

    with pytest.raises(TranslationError, match="steps.*non-empty"):
        await translate_chunk(
            db_session, embedding_client, chat_client,
            plan_name="test_plan", chunk_name="install_certs", source_text="apt install ca-certificates",
            similarity_threshold=0.85, max_retries=2,
        )

    assert len(chat_client.calls) == 3  # 1 initial + 2 retries, all exhausted


async def test_translate_chunk_raises_translation_error_on_chat_client_error(db_session):
    embedding_client = FakeEmbeddingClient()
    embedding_client.register("apt install ca-certificates", _vec(1.0, 0.0))
    chat_client = FakeChatClient(error=ChatClientError("endpoint unreachable"))

    with pytest.raises(TranslationError, match="endpoint unreachable"):
        await translate_chunk(
            db_session, embedding_client, chat_client,
            plan_name="test_plan", chunk_name="install_certs", source_text="apt install ca-certificates",
            similarity_threshold=0.85,
        )
