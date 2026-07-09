"""Unit tests for bossman.services.agent_client — httpx.MockTransport
intercepts at the HTTP layer (no real network, no real cert files needed:
httpx doesn't validate `cert=` paths when a custom transport is supplied),
letting these assert on exact request shape (URL, headers, query params)
and exercise error paths that would be awkward to trigger against a real
server. tests/test_poller.py and the real end-to-end run documented in
docs/plan.md cover this against an actual agentic-mcpd binary.
"""

from datetime import datetime, timezone

import httpx
import pytest

from bossman.services.agent_client import AgentClient, AgentClientError


def _client(handler, **kwargs):
    return AgentClient(
        address="agent.example.com:8010",
        token="tok",
        client_cert_path="/nonexistent/cert.pem",
        client_key_path="/nonexistent/key.pem",
        transport=httpx.MockTransport(handler),
        **kwargs,
    )


async def test_metrics_dump_sends_bearer_token_and_parses_response():
    seen = {}

    async def handler(request):
        seen["url"] = str(request.url)
        seen["auth"] = request.headers.get("authorization")
        return httpx.Response(200, json={"metrics": {"cpu_pct": [{"timestamp": "2026-07-04T12:00:00Z", "value": 1.5}]}})

    client = _client(handler)
    result = await client.metrics_dump(None)

    assert seen["url"] == "https://agent.example.com:8010/api/v1/metrics"
    assert seen["auth"] == "Bearer tok"
    assert result == {"cpu_pct": [{"timestamp": "2026-07-04T12:00:00Z", "value": 1.5}]}


async def test_metrics_dump_passes_from_as_utc_rfc3339():
    seen = {}

    async def handler(request):
        seen["query"] = dict(request.url.params)
        return httpx.Response(200, json={"metrics": {}})

    client = _client(handler)
    await client.metrics_dump(datetime(2026, 1, 1, 10, 30, 0, tzinfo=timezone.utc))

    assert seen["query"]["from"] == "2026-01-01T10:30:00Z"


async def test_connections_dump_parses_edges():
    async def handler(request):
        assert request.url.path == "/api/v1/net/connections/dump"
        return httpx.Response(200, json={"edges": [{"comm": "curl", "dst_addr": "1.1.1.1", "dst_port": 443}]})

    client = _client(handler)
    edges = await client.connections_dump(None)

    assert edges == [{"comm": "curl", "dst_addr": "1.1.1.1", "dst_port": 443}]


async def test_non_200_status_raises_agent_client_error():
    async def handler(request):
        return httpx.Response(401, text="unauthorized")

    client = _client(handler)
    with pytest.raises(AgentClientError, match="401"):
        await client.metrics_dump(None)


async def test_network_failure_raises_agent_client_error():
    async def handler(request):
        raise httpx.ConnectError("connection refused")

    client = _client(handler)
    with pytest.raises(AgentClientError, match="connection refused"):
        await client.metrics_dump(None)


async def test_invalid_json_raises_agent_client_error():
    async def handler(request):
        return httpx.Response(200, text="not json")

    client = _client(handler)
    with pytest.raises(AgentClientError):
        await client.metrics_dump(None)


async def test_missing_client_cert_raises_agent_client_error_not_bare_oserror():
    """Regression: a missing/unreadable mTLS cert/key file used to raise a
    bare FileNotFoundError from httpx.AsyncClient(cert=...)'s construction
    — uncaught by `except httpx.HTTPError`, so it escaped every per-agent
    try/except in poll_agent/poll_once entirely (found via a real
    background-poller crash during unrelated API tests, not by inspection).
    No MockTransport here on purpose: this must exercise real cert-path
    loading, which MockTransport bypasses."""
    client = AgentClient(
        address="agent.example.com:8010",
        token="tok",
        client_cert_path="/nonexistent/cert.pem",
        client_key_path="/nonexistent/key.pem",
    )
    with pytest.raises(AgentClientError, match="agent.example.com:8010"):
        await client.metrics_dump(None)


async def test_push_modules_posts_payload_and_parses_response():
    seen = {}

    async def handler(request):
        seen["url"] = str(request.url)
        seen["method"] = request.method
        import json as _json

        seen["body"] = _json.loads(request.content)
        return httpx.Response(200, json={"applied": 1, "results": [{"fqcn": "test.x", "ok": True}]})

    client = _client(handler)
    mods = [{"fqcn": "test.x", "star": "def main(ctx, params): return {'changed': False, 'msg': 'ok'}",
             "sidecar": "name: x\n", "sidecar_format": "yaml", "sha256": "abc"}]
    result = await client.push_modules(mods)

    assert seen["method"] == "POST"
    assert seen["url"] == "https://agent.example.com:8010/api/v1/modules/apply"
    assert seen["body"] == {"modules": mods}
    assert result == {"applied": 1, "results": [{"fqcn": "test.x", "ok": True}]}


async def test_push_modules_raises_on_non_200():
    async def handler(request):
        return httpx.Response(403, text="module delivery is disabled (write=false)")

    client = _client(handler)
    with pytest.raises(AgentClientError, match="push modules returned 403"):
        await client.push_modules([{"fqcn": "test.x", "star": "", "sidecar": "", "sidecar_format": "yaml", "sha256": ""}])
