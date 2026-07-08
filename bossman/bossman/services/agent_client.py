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
from typing import TYPE_CHECKING, Any

import httpx

if TYPE_CHECKING:
    from bossman.config import Settings
    from bossman.db.models import Agent


class AgentClientError(Exception):
    """Raised when a pull against an agent fails (network, auth, a non-200
    response, or a local OSError — e.g. Bossman's own mTLS cert/key file
    missing/unreadable) — always carries a human-readable message, since
    the poller only logs/records this, it doesn't retry inline. Real bug
    found via testing: an earlier version only caught httpx.HTTPError, so
    a missing cert file (a bare FileNotFoundError from
    httpx.AsyncClient(cert=...)'s construction) escaped every per-agent
    try/except in poll_agent/poll_once entirely, defeating the "one bad
    agent's failure is isolated" design and disrupting sibling polls in
    the same asyncio.gather."""


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
        except (httpx.HTTPError, OSError) as exc:
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

    async def hosts_overview(self) -> list[dict[str, Any]]:
        """GET /api/v1/hosts/overview — every host this agent currently
        knows about: itself alone (standalone/satellite mode), or itself
        plus every satellite it is polling (proxy mode) — see
        docs/plan.md's monitoring-cockpit ergänzung Block F1. Each entry
        is `{host, parent?, mode, last_sample_at?, metrics: [...],
        checks: [...]}`. No cursor: this is always a full "latest state"
        snapshot, not a history pull."""
        body = await self._get_json("/api/v1/hosts/overview", {})
        return body.get("hosts", [])

    async def processes(self, limit: int = 0) -> dict[str, Any]:
        """GET /api/v1/processes — the agent's live process table (Block J1):
        per-PID CPU%/RSS/owner/command plus eBPF enrichment (container id,
        outbound connections). Sampled on demand by the agent, so this is a
        pass-through, never stored. `limit` (>0) keeps only the top-N
        hungriest; 0 = all."""
        params: dict[str, str] = {}
        if limit > 0:
            params["limit"] = str(limit)
        return await self._get_json("/api/v1/processes", params)

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
        except (httpx.HTTPError, OSError) as exc:
            raise AgentClientError(f"{self.address}: tool {name!r}: request failed: {exc}") from exc

        if resp.status_code != 200:
            raise AgentClientError(f"{self.address}: tool {name!r} returned {resp.status_code}: {resp.text[:4096]}")
        try:
            return resp.json()
        except ValueError as exc:
            raise AgentClientError(f"{self.address}: tool {name!r}: decoding response: {exc}") from exc

    async def apply_config(self, generation: int, config_hash: str, state: dict[str, Any]) -> dict[str, Any]:
        """POST /api/v1/config/apply — PUSH the compiled desired state to the
        agent (Block L4, docs/policy-orchestration-architecture.md §6). This
        is the controller→agent direction that keeps the firewall to a single
        rule (Bossman → agent); the agent never dials out. The agent's JSON
        response is the ack the reconciler records ({status:
        "applied"|"unchanged", generation})."""
        url = f"https://{self.address}/api/v1/config/apply"
        payload = {"generation": generation, "config_hash": config_hash, "state": state}
        try:
            async with self._client() as client:
                resp = await client.post(url, json=payload)
        except (httpx.HTTPError, OSError) as exc:
            raise AgentClientError(f"{self.address}: config apply: request failed: {exc}") from exc

        if resp.status_code != 200:
            raise AgentClientError(f"{self.address}: config apply returned {resp.status_code}: {resp.text[:4096]}")
        try:
            return resp.json()
        except ValueError as exc:
            raise AgentClientError(f"{self.address}: config apply: decoding response: {exc}") from exc

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
        except (httpx.HTTPError, OSError) as exc:
            raise AgentClientError(f"{self.address}: upload {remote_name!r}: request failed: {exc}") from exc

        if resp.status_code != 200:
            raise AgentClientError(
                f"{self.address}: upload {remote_name!r} returned {resp.status_code}: {resp.text[:4096]}"
            )
        try:
            return resp.json()
        except ValueError as exc:
            raise AgentClientError(f"{self.address}: upload {remote_name!r}: decoding response: {exc}") from exc


def client_for(agent: Agent, settings: Settings) -> AgentClient:
    """Builds the AgentClient for talking to agent using Bossman's own
    mTLS client identity — the one shared construction path used by both
    the background poller (services/poller.py) and the plan-run REST
    route (api/plans.py), so there's exactly one place that knows how an
    agent's stored address/token map to a live connection."""
    return AgentClient(
        address=agent.address,
        token=agent.token,
        client_cert_path=settings.client_cert_path,
        client_key_path=settings.client_key_path,
    )
