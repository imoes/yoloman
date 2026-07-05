"""Unit tests for bossman.services.embedding_client — httpx.MockTransport
intercepts at the HTTP layer (no real network needed). A real end-to-end
run against the actual bge-m3 endpoint is documented in docs/plan.md's
"Chunk-similarity embedding cache" section, not repeated here.
"""

import json

import httpx
import pytest

from bossman.services.embedding_client import EmbeddingClient, EmbeddingClientError


def _client(handler, **kwargs):
    return EmbeddingClient(
        base_url="https://embed.example.com",
        model="bge-m3",
        expected_dim=4,
        transport=httpx.MockTransport(handler),
        **kwargs,
    )


async def test_embed_sends_model_and_input_returns_vectors_in_order():
    seen = {}

    async def handler(request):
        seen["url"] = str(request.url)
        seen["body"] = request.read()
        return httpx.Response(
            200,
            json={
                "data": [
                    {"index": 1, "embedding": [0.5, 0.5, 0.5, 0.5]},
                    {"index": 0, "embedding": [0.1, 0.2, 0.3, 0.4]},
                ]
            },
        )

    client = _client(handler)
    vectors = await client.embed(["first", "second"])

    assert seen["url"] == "https://embed.example.com/v1/embeddings"
    body = json.loads(seen["body"])
    assert body == {"model": "bge-m3", "input": ["first", "second"]}
    # re-sorted by the response's own `index`, not assumed positional
    assert vectors == [[0.1, 0.2, 0.3, 0.4], [0.5, 0.5, 0.5, 0.5]]


async def test_embed_sends_bearer_token_when_configured():
    seen = {}

    async def handler(request):
        seen["auth"] = request.headers.get("authorization")
        return httpx.Response(200, json={"data": [{"index": 0, "embedding": [0.0, 0.0, 0.0, 0.0]}]})

    client = _client(handler, token="secret-token")
    await client.embed(["x"])

    assert seen["auth"] == "Bearer secret-token"


async def test_embed_omits_auth_header_when_no_token():
    seen = {}

    async def handler(request):
        seen["auth"] = request.headers.get("authorization")
        return httpx.Response(200, json={"data": [{"index": 0, "embedding": [0.0, 0.0, 0.0, 0.0]}]})

    client = _client(handler)
    await client.embed(["x"])

    assert seen["auth"] is None


async def test_embed_raises_on_non_200():
    async def handler(request):
        return httpx.Response(501, json={"error": {"message": "not supported"}})

    client = _client(handler)
    with pytest.raises(EmbeddingClientError, match="501"):
        await client.embed(["x"])


async def test_embed_raises_on_network_failure():
    async def handler(request):
        raise httpx.ConnectError("connection refused")

    client = _client(handler)
    with pytest.raises(EmbeddingClientError, match="request failed"):
        await client.embed(["x"])


async def test_embed_raises_on_invalid_json():
    async def handler(request):
        return httpx.Response(200, content=b"not json")

    client = _client(handler)
    with pytest.raises(EmbeddingClientError, match="decoding response"):
        await client.embed(["x"])


async def test_embed_raises_on_unexpected_response_shape():
    async def handler(request):
        return httpx.Response(200, json={"error": {"message": "no embeddings support"}})

    client = _client(handler)
    with pytest.raises(EmbeddingClientError, match="unexpected response shape"):
        await client.embed(["x"])


async def test_embed_raises_on_wrong_vector_count():
    async def handler(request):
        return httpx.Response(200, json={"data": [{"index": 0, "embedding": [0.0, 0.0, 0.0, 0.0]}]})

    client = _client(handler)
    with pytest.raises(EmbeddingClientError, match="expected 2 vectors, got 1"):
        await client.embed(["first", "second"])


async def test_embed_raises_on_dimension_mismatch():
    async def handler(request):
        # A 3-dim vector against an expected_dim=4 client — the guard that
        # catches "wrong model/endpoint" mistakes early rather than
        # letting a malformed vector silently reach pgvector.
        return httpx.Response(200, json={"data": [{"index": 0, "embedding": [0.1, 0.2, 0.3]}]})

    client = _client(handler)
    with pytest.raises(EmbeddingClientError, match="expected 4-dim"):
        await client.embed(["x"])
