"""A qualify client (max_attempts=None, timeout=None) keeps waiting through gateway 504s instead of giving up."""

import httpx
import pytest

from bossman.services import chat_client
from bossman.services.chat_client import ChatClient


@pytest.mark.asyncio
async def test_unbounded_client_retries_past_the_default_limit(monkeypatch):
    calls = {"n": 0}

    def handler(request):
        calls["n"] += 1
        if calls["n"] <= 12:   # more than the default 8 attempts
            return httpx.Response(504, text="<html>504 Gateway Time-out</html>")
        return httpx.Response(200, json={"choices": [{"message": {"content": "ok"}, "finish_reason": "stop"}]})

    async def no_sleep(_):
        return None

    monkeypatch.setattr(chat_client.asyncio, "sleep", no_sleep)
    client = ChatClient("http://llm", "m", timeout=None, max_attempts=None, transport=httpx.MockTransport(handler))
    body = await client._post({"messages": []})
    assert body["choices"][0]["message"]["content"] == "ok" and calls["n"] == 13


@pytest.mark.asyncio
async def test_the_default_client_still_gives_up(monkeypatch):
    async def no_sleep(_):
        return None

    monkeypatch.setattr(chat_client.asyncio, "sleep", no_sleep)
    client = ChatClient("http://llm", "m", transport=httpx.MockTransport(lambda r: httpx.Response(504, text="x")))
    with pytest.raises(chat_client.ChatClientError, match="giving up"):
        await client._post({"messages": []})
