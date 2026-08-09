"""A thin async HTTP client for an OpenAI-compatible embedding endpoint —
the fuzzy layer behind the chunk-similarity cache (see
services/chunk_similarity.py and docs/plan.md's "Chunk-similarity embedding
cache"). Mirrors services/agent_client.py's AgentClient shape (error type,
client factory, transport test-seam, central JSON-decode helper), but with
a normal `verify=True` TLS connection and no client certificate — this
endpoint is a plain internal HTTPS service with a valid certificate and
(currently) no auth, not a pinned-key node agent.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

import httpx

if TYPE_CHECKING:
    from bossman.config import Settings


class EmbeddingClientError(Exception):
    """Raised when an embedding call fails (network, auth, a non-200
    response, or a response whose vectors don't match the configured
    dimension) — always carries a human-readable message."""


class EmbeddingClient:
    """One embedding endpoint's identity: base URL, model name, and
    optional bearer token."""

    def __init__(
        self,
        base_url: str,
        model: str,
        expected_dim: int,
        token: str = "",
        timeout: float = 30.0,
        transport: httpx.AsyncBaseTransport | None = None,
    ):
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.expected_dim = expected_dim
        self.token = token
        self._timeout = timeout
        # Only ever set by tests (httpx.MockTransport) — None means "use
        # httpx's normal network transport", the same test seam
        # AgentClient uses.
        self._transport = transport

    def _client(self) -> httpx.AsyncClient:
        headers = {"Authorization": f"Bearer {self.token}"} if self.token else {}
        return httpx.AsyncClient(timeout=self._timeout, headers=headers, transport=self._transport)

    async def embed(self, texts: list[str]) -> list[list[float]]:
        """Embeds one or more texts in a single batched call, returning one
        vector per input in the same order (the endpoint's own `index`
        field is used to re-sort, in case of a service that batches
        out-of-order rather than trusting positional order)."""
        url = f"{self.base_url}/v1/embeddings"
        try:
            async with self._client() as client:
                resp = await client.post(url, json={"model": self.model, "input": texts})
        except httpx.HTTPError as exc:
            raise EmbeddingClientError(f"{self.base_url}: request failed: {exc}") from exc

        if resp.status_code != 200:
            raise EmbeddingClientError(f"{self.base_url}: unexpected status {resp.status_code}: {resp.text[:4096]}")
        try:
            body = resp.json()
        except ValueError as exc:
            raise EmbeddingClientError(f"{self.base_url}: decoding response: {exc}") from exc

        try:
            rows = sorted(body["data"], key=lambda row: row["index"])
            vectors = [row["embedding"] for row in rows]
        except (KeyError, TypeError) as exc:
            raise EmbeddingClientError(f"{self.base_url}: unexpected response shape: {exc}") from exc

        if len(vectors) != len(texts):
            raise EmbeddingClientError(f"{self.base_url}: expected {len(texts)} vectors, got {len(vectors)}")
        for vec in vectors:
            if len(vec) != self.expected_dim:
                raise EmbeddingClientError(
                    f"{self.base_url}: expected {self.expected_dim}-dim vectors, got {len(vec)} "
                    "(wrong model or endpoint?)"
                )
        return vectors


def embedding_client_for(settings: Settings) -> EmbeddingClient:
    """Builds the EmbeddingClient from Settings — the one shared
    construction path, mirroring agent_client.client_for."""
    return EmbeddingClient(
        base_url=settings.embedding_base_url,
        model=settings.embedding_model,
        expected_dim=settings.embedding_dim,
        token=settings.embedding_token,
    )
