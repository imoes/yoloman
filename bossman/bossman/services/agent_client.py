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

    async def healthz(self) -> dict[str, Any]:
        """GET /healthz — `{"status": "ok", "version": "0.57.36"}`.

        The agent's own build version, which Checkmk shows as part of its agent service
        and which an operator needs before asking anything about behaviour ("is this the
        host still on the old collector?"). Note this endpoint is deliberately
        unauthenticated on the agent side (see cmd/agentic-mcpd/http.go), so it answers
        even for a host whose token has drifted — useful, because "reachable but
        rejecting our token" is a different fault from "gone".
        """
        return await self._get_json("/healthz", {})

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

    async def piggyback_sources(self) -> list[dict[str, Any]]:
        """GET /api/v1/piggyback/sources (F-9) — the configured piggyback
        sources on this host + a live status each: `{type, target, kind,
        reachable, guest_count, error}`. Read-only; the agent probes each
        source once per request."""
        body = await self._get_json("/api/v1/piggyback/sources", {})
        return body.get("sources", [])

    async def add_piggyback_source(self, body: dict[str, Any]) -> dict[str, Any]:
        """POST /api/v1/piggyback/sources (F-9) — add/replace a remote Proxmox/
        vSphere endpoint; the agent persists it to config.yaml + reloads its
        collectors (write-gated)."""
        url = f"https://{self.address}/api/v1/piggyback/sources"
        try:
            async with self._client() as client:
                resp = await client.post(url, json=body)
        except (httpx.HTTPError, OSError) as exc:
            raise AgentClientError(f"{self.address}: add piggyback source: {exc}") from exc
        if resp.status_code != 200:
            raise AgentClientError(f"{self.address}: add piggyback source returned {resp.status_code}: {resp.text[:1024]}")
        return resp.json()

    async def remove_piggyback_source(self, source_type: str, host: str) -> dict[str, Any]:
        """DELETE /api/v1/piggyback/sources?type=&host= (F-9)."""
        url = f"https://{self.address}/api/v1/piggyback/sources"
        try:
            async with self._client() as client:
                resp = await client.delete(url, params={"type": source_type, "host": host})
        except (httpx.HTTPError, OSError) as exc:
            raise AgentClientError(f"{self.address}: remove piggyback source: {exc}") from exc
        if resp.status_code != 200:
            raise AgentClientError(f"{self.address}: remove piggyback source returned {resp.status_code}: {resp.text[:1024]}")
        return resp.json()

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

    async def ebpf_top_talkers(self, limit: int = 20) -> dict[str, Any]:
        """GET /api/v1/net/top-talkers — the eBPF window's most-frequent
        outbound connection targets (comm → dst:port, connect count). On-demand
        pass-through; the 'what' behind the connect-latency heatmap."""
        return await self._get_json("/api/v1/net/top-talkers", {"limit": str(limit)})

    async def ebpf_slowest_disk_io(self, limit: int = 20) -> dict[str, Any]:
        """GET /api/v1/disk-io/slowest — the slowest recent block-I/O requests
        (comm, device, latency, op). On-demand pass-through; the 'what' behind
        the disk-I/O-latency heatmap."""
        return await self._get_json("/api/v1/disk-io/slowest", {"limit": str(limit)})

    async def ebpf_oom_kills(self, limit: int = 20) -> dict[str, Any]:
        """GET /api/v1/oom-kills — processes the kernel OOM killer terminated
        (BCC oomkill). On-demand pass-through."""
        return await self._get_json("/api/v1/oom-kills", {"limit": str(limit)})

    async def ebpf_tcp_retransmits(self, limit: int = 20) -> dict[str, Any]:
        """GET /api/v1/tcp-retransmits — recent TCP retransmissions per
        connection (BCC tcpretrans). On-demand pass-through."""
        return await self._get_json("/api/v1/tcp-retransmits", {"limit": str(limit)})

    async def ebpf_signals(self, limit: int = 20) -> dict[str, Any]:
        """GET /api/v1/signals — recent notable signal deliveries, sender →
        target (BCC killsnoop). On-demand pass-through."""
        return await self._get_json("/api/v1/signals", {"limit": str(limit)})

    async def ebpf_runq_latency(self) -> dict[str, Any]:
        """GET /api/v1/runq-latency — run-queue latency histogram, a CPU-
        saturation signal (BCC runqlat). On-demand pass-through."""
        return await self._get_json("/api/v1/runq-latency", {})

    async def ebpf_l7_requests(self, protocol: str = "", limit: int = 50) -> dict[str, Any]:
        """GET /api/v1/l7[?protocol=] — recent passive-L7 exchanges
        (DNS/HTTP/Postgres/MySQL) captured via syscall tracepoints, each with
        protocol, request text, classified status, latency and destination.
        On-demand pass-through (Tier-2)."""
        params = {"limit": str(limit)}
        if protocol:
            params["protocol"] = protocol
        return await self._get_json("/api/v1/l7", params)

    async def list_tools(self) -> list[dict[str, Any]]:
        """GET /api/v1/tools — every module/task/pipeline tool this agent
        currently exposes: [{name, kind, writes}]. Write tools are only
        present when the agent's write gate is open, so the list already
        reflects what the caller may actually invoke. Powers Bossman's MCP
        router (list_agent_tools) and the REST tool-listing proxy."""
        body = await self._get_json("/api/v1/tools", {})
        return body.get("tools", [])

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

    async def state_observed(self) -> dict[str, Any]:
        """GET /api/v1/state/observed — the whole server as one JSON document:
        discovered services + each config file read back (structured via its
        codec, else a sha256 ref). The read side of the server-as-a-document
        model (docs: project-server-as-document)."""
        return await self._get_json("/api/v1/state/observed", {})

    async def state_generations(self) -> dict[str, Any]:
        """GET /api/v1/state/generations — the agent's local desired-state
        generation history (plan/apply/rollback store), newest first."""
        return await self._get_json("/api/v1/state/generations", {})

    async def state_plan(self, document: dict[str, Any]) -> dict[str, Any]:
        """POST /api/v1/state/plan — diff a desired Document (list of config
        resources with target values) against the host, returning the per-key
        plan without writing. The read side of edit → plan → apply."""
        url = f"https://{self.address}/api/v1/state/plan"
        try:
            async with self._client() as client:
                resp = await client.post(url, json=document)
        except (httpx.HTTPError, OSError) as exc:
            raise AgentClientError(f"{self.address}: state plan: request failed: {exc}") from exc
        if resp.status_code != 200:
            raise AgentClientError(f"{self.address}: state plan returned {resp.status_code}: {resp.text[:4096]}")
        try:
            return resp.json()
        except ValueError as exc:
            raise AgentClientError(f"{self.address}: state plan: decoding response: {exc}") from exc

    async def state_apply(self, document: dict[str, Any], dry_run: bool) -> dict[str, Any]:
        """POST /api/v1/state/apply — converge a desired Document; records a new
        generation when anything changed (unless dry_run). The write side of the
        document loop — real config edits go through here, not ad-hoc tool
        calls, so they are diffable, versioned and roll-backable."""
        url = f"https://{self.address}/api/v1/state/apply"
        try:
            async with self._client() as client:
                resp = await client.post(url, json={**document, "dry_run": dry_run})
        except (httpx.HTTPError, OSError) as exc:
            raise AgentClientError(f"{self.address}: state apply: request failed: {exc}") from exc
        if resp.status_code != 200:
            raise AgentClientError(f"{self.address}: state apply returned {resp.status_code}: {resp.text[:4096]}")
        try:
            return resp.json()
        except ValueError as exc:
            raise AgentClientError(f"{self.address}: state apply: decoding response: {exc}") from exc

    async def state_rollback(self, generation: int, dry_run: bool) -> dict[str, Any]:
        """POST /api/v1/state/rollback — roll the host's config back to a past
        generation. dry_run=true returns the plan (the diff observed→target)
        without writing; a real rollback needs the agent's write gate open
        (else the agent 403s, surfaced upstream as 502)."""
        url = f"https://{self.address}/api/v1/state/rollback"
        try:
            async with self._client() as client:
                resp = await client.post(url, json={"generation": generation, "dry_run": dry_run})
        except (httpx.HTTPError, OSError) as exc:
            raise AgentClientError(f"{self.address}: state rollback: request failed: {exc}") from exc
        if resp.status_code != 200:
            raise AgentClientError(f"{self.address}: state rollback returned {resp.status_code}: {resp.text[:4096]}")
        try:
            return resp.json()
        except ValueError as exc:
            raise AgentClientError(f"{self.address}: state rollback: decoding response: {exc}") from exc

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

    async def self_update(self, deb: bytes) -> dict[str, Any]:
        """POST /api/v1/agent/self-update — PUSH a new agent .deb over the
        existing mTLS channel; the agent installs it (dpkg → postinst restart)
        and comes back on the new version. This endpoint is the deliberate
        write-gate carve-out: it works even against a read-only (write=false)
        agent, since an agent must stay upgradable. Raw octet-stream body."""
        url = f"https://{self.address}/api/v1/agent/self-update"
        try:
            async with self._client() as client:
                resp = await client.post(
                    url, content=deb, headers={"Content-Type": "application/octet-stream"}
                )
        except (httpx.HTTPError, OSError) as exc:
            raise AgentClientError(f"{self.address}: self-update: request failed: {exc}") from exc
        if resp.status_code != 200:
            raise AgentClientError(f"{self.address}: self-update returned {resp.status_code}: {resp.text[:4096]}")
        try:
            return resp.json()
        except ValueError as exc:
            raise AgentClientError(f"{self.address}: self-update: decoding response: {exc}") from exc

    async def set_collect_config(self, patch: dict[str, Any]) -> dict[str, Any]:
        """POST /api/v1/agent/collect-config — change the agent's metric-collection
        knobs (services/psi/docker/drbd_devices/interval) and let it
        restart to apply. Like self_update this is the write-gate carve-out: it
        works against a read-only agent, because an agent that collects the wrong
        thing must be fixable without first being made writable. Only the keys
        present in `patch` are changed; the endpoint can touch nothing outside the
        collect block."""
        url = f"https://{self.address}/api/v1/agent/collect-config"
        try:
            async with self._client() as client:
                resp = await client.post(url, json=patch)
        except (httpx.HTTPError, OSError) as exc:
            raise AgentClientError(f"{self.address}: collect-config: request failed: {exc}") from exc
        if resp.status_code != 200:
            raise AgentClientError(f"{self.address}: collect-config returned {resp.status_code}: {resp.text[:4096]}")
        try:
            return resp.json()
        except ValueError as exc:
            raise AgentClientError(f"{self.address}: collect-config: decoding response: {exc}") from exc

    async def push_modules(self, modules: list[dict[str, Any]]) -> dict[str, Any]:
        """POST /api/v1/modules/apply — PUSH translated Starlark modules to the
        agent (Block G3). Each entry is {fqcn, star, sidecar, sidecar_format,
        sha256}; the agent verifies, validates (parse+lint), persists, and
        live-registers each. Requires the agent's write gate open (403
        otherwise). Controller→agent direction (the agent never dials out)."""
        url = f"https://{self.address}/api/v1/modules/apply"
        try:
            async with self._client() as client:
                resp = await client.post(url, json={"modules": modules})
        except (httpx.HTTPError, OSError) as exc:
            raise AgentClientError(f"{self.address}: push modules: request failed: {exc}") from exc
        if resp.status_code != 200:
            raise AgentClientError(f"{self.address}: push modules returned {resp.status_code}: {resp.text[:4096]}")
        try:
            return resp.json()
        except ValueError as exc:
            raise AgentClientError(f"{self.address}: push modules: decoding response: {exc}") from exc

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
