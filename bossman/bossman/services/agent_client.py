"""A thin async HTTP client for one node agent's bulk-dump REST endpoints
(see docs/plan.md's Bossman plan, section B.4).

Mirrors the Go proxy's own `internal/fleet.Puller` byte for byte in
protocol terms: `Authorization: Bearer <token>`, a client certificate
presented for mTLS, `verify=False` (Bossman does not verify the agent's
server identity — the trust runs the other way, the agent verifies
Bossman's client certificate against its own pinned
`tls.trusted_client_keys`, the same accepted trade-off already documented
for proxy mode). No CA bundle is configured for the identical reason.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

import httpx


class AgentClientError(Exception):
    """Raised when a pull against an agent fails (network, auth, or a
    non-200 response) — always carries a human-readable message, since
    the poller only logs/records this, it doesn't retry inline."""


class AgentClient:
    """One agent's REST identity: its address plus the credentials needed
    to poll it (bearer token + Bossman's own mTLS client identity)."""

    def __init__(
        self,
        address: str,
        token: str,
        client_cert_path: str,
        client_key_path: str,
        timeout: float = 30.0,
        transport: httpx.AsyncBaseTransport | None = None,
    ):
        self.address = address
        self.token = token
        self._client_cert_path = client_cert_path
        self._client_key_path = client_key_path
        self._timeout = timeout
        # Only ever set by tests (httpx.MockTransport) — None means "use
        # httpx's normal network transport", which is what every real
        # (non-test) caller gets.
        self._transport = transport

    def _client(self) -> httpx.AsyncClient:
        headers = {"Authorization": f"Bearer {self.token}"} if self.token else {}
        return httpx.AsyncClient(
            cert=(self._client_cert_path, self._client_key_path),
            verify=False,
            timeout=self._timeout,
            headers=headers,
            transport=self._transport,
        )

    async def _get_json(self, path: str, params: dict[str, str]) -> Any:
        url = f"https://{self.address}{path}"
        try:
            async with self._client() as client:
                resp = await client.get(url, params=params)
        except httpx.HTTPError as exc:
            raise AgentClientError(f"{self.address}: request failed: {exc}") from exc

        if resp.status_code != 200:
            raise AgentClientError(f"{self.address}: unexpected status {resp.status_code}: {resp.text[:4096]}")
        try:
            return resp.json()
        except ValueError as exc:
            raise AgentClientError(f"{self.address}: decoding response: {exc}") from exc

    async def metrics_dump(self, from_: datetime | None) -> dict[str, list[dict[str, Any]]]:
        """GET /api/v1/metrics — every metric this agent knows about since
        `from_` (RFC3339, UTC), or the agent's own default range (last 1h)
        if `from_` is None (first pull, no cursor yet)."""
        params: dict[str, str] = {}
        if from_ is not None:
            params["from"] = from_.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        body = await self._get_json("/api/v1/metrics", params)
        return body.get("metrics", {})

    async def connections_dump(self, since: datetime | None) -> list[dict[str, Any]]:
        """GET /api/v1/net/connections/dump — every persisted connection
        edge last seen at or after `since`, or the agent's own default
        range (last 24h) if `since` is None."""
        params: dict[str, str] = {}
        if since is not None:
            params["since"] = since.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        body = await self._get_json("/api/v1/net/connections/dump", params)
        return body.get("edges", [])

    async def call_tool(self, name: str, body: dict[str, Any]) -> dict[str, Any]:
        """POST /api/v1/tools/{name} — invoke one module/task/pipeline
        tool (see docs/plan.md's Bossman plan, section B.5's plan engine).
        Raises AgentClientError on any non-200 response or network
        failure — the plan engine wraps each step call so a single failing
        step doesn't crash the whole run."""
        url = f"https://{self.address}/api/v1/tools/{name}"
        try:
            async with self._client() as client:
                resp = await client.post(url, json=body)
        except httpx.HTTPError as exc:
            raise AgentClientError(f"{self.address}: tool {name!r}: request failed: {exc}") from exc

        if resp.status_code != 200:
            raise AgentClientError(f"{self.address}: tool {name!r} returned {resp.status_code}: {resp.text[:4096]}")
        try:
            return resp.json()
        except ValueError as exc:
            raise AgentClientError(f"{self.address}: tool {name!r}: decoding response: {exc}") from exc

    async def upload_file(self, remote_name: str, data: bytes) -> dict[str, Any]:
        """PUT /api/v1/upload?name=<remote_name> — the raw-body,
        no-base64 large-file upload path (see docs/plan.md's "File upload
        (staging)"). The entire body is the file's raw bytes, not JSON."""
        url = f"https://{self.address}/api/v1/upload"
        try:
            async with self._client() as client:
                resp = await client.put(
                    url,
                    params={"name": remote_name},
                    content=data,
                    headers={"Content-Type": "application/octet-stream"},
                )
        except httpx.HTTPError as exc:
            raise AgentClientError(f"{self.address}: upload {remote_name!r}: request failed: {exc}") from exc

        if resp.status_code != 200:
            raise AgentClientError(
                f"{self.address}: upload {remote_name!r} returned {resp.status_code}: {resp.text[:4096]}"
            )
        try:
            return resp.json()
        except ValueError as exc:
            raise AgentClientError(f"{self.address}: upload {remote_name!r}: decoding response: {exc}") from exc
