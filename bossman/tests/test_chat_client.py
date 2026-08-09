"""Unit tests for bossman.services.chat_client — httpx.MockTransport
intercepts at the HTTP layer (no real network needed). A real end-to-end
run against the actual qwen79b endpoint is documented in docs/plan.md's
"real LLM translator" section, not repeated here.
"""

import json

import httpx
import pytest

from bossman.services.chat_client import ChatClient, ChatClientError

SIMPLE_SCHEMA = {"type": "object", "properties": {"answer": {"type": "string"}}, "required": ["answer"]}


def _client(handler, **kwargs):
    return ChatClient(
        base_url="https://chat.example.com",
        model="qwen3next-79b",
        transport=httpx.MockTransport(handler),
        **kwargs,
    )


async def test_complete_json_sends_schema_and_parses_content():
    seen = {}

    async def handler(request):
        seen["url"] = str(request.url)
        seen["body"] = json.loads(request.read())
        return httpx.Response(
            200,
            json={
                "choices": [{"message": {"role": "assistant", "content": '{"answer": "42"}'}}],
                "usage": {"prompt_tokens": 10, "completion_tokens": 5},
            },
        )

    client = _client(handler)
    result = await client.complete_json([{"role": "user", "content": "what?"}], SIMPLE_SCHEMA, "answer_schema")

    assert seen["url"] == "https://chat.example.com/v1/chat/completions"
    assert seen["body"]["model"] == "qwen3next-79b"
    assert seen["body"]["messages"] == [{"role": "user", "content": "what?"}]
    assert seen["body"]["response_format"] == {
        "type": "json_schema",
        "json_schema": {"name": "answer_schema", "schema": SIMPLE_SCHEMA},
    }
    assert result == {"answer": "42"}


async def test_complete_json_sends_bearer_token_when_configured():
    seen = {}

    async def handler(request):
        seen["auth"] = request.headers.get("authorization")
        return httpx.Response(200, json={"choices": [{"message": {"content": "{}"}}]})

    client = _client(handler, token="secret-token")
    await client.complete_json([], SIMPLE_SCHEMA, "s")

    assert seen["auth"] == "Bearer secret-token"


async def test_complete_json_omits_auth_header_when_no_token():
    seen = {}

    async def handler(request):
        seen["auth"] = request.headers.get("authorization")
        return httpx.Response(200, json={"choices": [{"message": {"content": "{}"}}]})

    client = _client(handler)
    await client.complete_json([], SIMPLE_SCHEMA, "s")

    assert seen["auth"] is None


async def test_complete_json_strips_markdown_fence_defensively():
    async def handler(request):
        return httpx.Response(200, json={"choices": [{"message": {"content": '```json\n{"answer": "x"}\n```'}}]})

    client = _client(handler)
    result = await client.complete_json([], SIMPLE_SCHEMA, "s")

    assert result == {"answer": "x"}


async def test_complete_json_raises_on_non_200():
    async def handler(request):
        return httpx.Response(500, text="internal error")

    client = _client(handler)
    with pytest.raises(ChatClientError, match="500"):
        await client.complete_json([], SIMPLE_SCHEMA, "s")


async def test_complete_json_raises_on_network_failure():
    async def handler(request):
        raise httpx.ConnectError("connection refused")

    client = _client(handler)
    with pytest.raises(ChatClientError, match="request failed"):
        await client.complete_json([], SIMPLE_SCHEMA, "s")


async def test_complete_json_raises_on_invalid_response_json():
    async def handler(request):
        return httpx.Response(200, content=b"not json")

    client = _client(handler)
    with pytest.raises(ChatClientError, match="decoding response"):
        await client.complete_json([], SIMPLE_SCHEMA, "s")


async def test_complete_json_raises_on_unexpected_response_shape():
    async def handler(request):
        return httpx.Response(200, json={"error": {"message": "bad request"}})

    client = _client(handler)
    with pytest.raises(ChatClientError, match="unexpected response shape"):
        await client.complete_json([], SIMPLE_SCHEMA, "s")


async def test_complete_json_raises_on_non_json_content():
    async def handler(request):
        return httpx.Response(200, json={"choices": [{"message": {"content": "this is not json at all"}}]})

    client = _client(handler)
    with pytest.raises(ChatClientError, match="not valid JSON"):
        await client.complete_json([], SIMPLE_SCHEMA, "s")
