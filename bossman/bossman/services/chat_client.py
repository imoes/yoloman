"""A thin async HTTP client for an OpenAI-compatible chat-completions
endpoint — the LLM behind services/translator.py's real translation path
(see docs/plan.md's "real LLM translator"). Mirrors
services/embedding_client.py's EmbeddingClient shape (error type, client
factory, transport test-seam, central JSON-decode helper) — a different
model/path on the same host as the embedding endpoint (qwen3next-79b,
completion-only; confirmed by probing it directly that it does not serve
embeddings itself, unlike the sibling bge-m3 deployment).

response_format: {"type": "json_schema", ...} is used rather than free-
text prompting: verified against the real endpoint that this constrains
generation at the grammar level (llama.cpp/GBNF), including schemas with
dotted-key literal property names — the LLM cannot emit syntactically
invalid JSON, only semantically wrong content, which is what
plan_loader.parse_plan (via services/translator.py) is left to catch.
"""

from __future__ import annotations

import json
import logging
from typing import TYPE_CHECKING

import httpx

if TYPE_CHECKING:
    from bossman.config import Settings

logger = logging.getLogger(__name__)


class ChatClientError(Exception):
    """Raised when a chat-completion call fails (network, auth, a non-200
    response, or a response whose content isn't valid JSON) — always
    carries a human-readable message."""


class ChatClient:
    """One chat-completions endpoint's identity: base URL, model name, and
    optional bearer token."""

    def __init__(
        self,
        base_url: str,
        model: str,
        token: str = "",
        # A 79B-parameter model with a long context can take a while to
        # generate several hundred output tokens — a real basic probe
        # against this endpoint measured ~79 tokens/sec on a trivial
        # completion, so a multi-hundred-token structured translation is
        # comfortably a tens-of-seconds affair; 300s leaves real headroom.
        timeout: float = 300.0,
        transport: httpx.AsyncBaseTransport | None = None,
    ):
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.token = token
        self._timeout = timeout
        # Only ever set by tests (httpx.MockTransport) — None means "use
        # httpx's normal network transport", the same test seam
        # EmbeddingClient/AgentClient use.
        self._transport = transport

    def _client(self) -> httpx.AsyncClient:
        headers = {"Authorization": f"Bearer {self.token}"} if self.token else {}
        return httpx.AsyncClient(timeout=self._timeout, headers=headers, transport=self._transport)

    async def complete_json(
        self,
        messages: list[dict[str, str]],
        json_schema: dict,
        schema_name: str,
        max_tokens: int = 4000,
    ) -> dict:
        """Sends a chat-completion request constrained to json_schema and
        returns the decoded response content as a dict. Raises
        ChatClientError on any network/status/decode failure — never
        returns a partial or best-effort result."""
        url = f"{self.base_url}/v1/chat/completions"
        body = {
            "model": self.model,
            "messages": messages,
            "max_tokens": max_tokens,
            "response_format": {"type": "json_schema", "json_schema": {"name": schema_name, "schema": json_schema}},
        }
        try:
            async with self._client() as client:
                resp = await client.post(url, json=body)
        except httpx.HTTPError as exc:
            raise ChatClientError(f"{self.base_url}: request failed: {exc}") from exc

        if resp.status_code != 200:
            raise ChatClientError(f"{self.base_url}: unexpected status {resp.status_code}: {resp.text[:4096]}")
        try:
            response_body = resp.json()
        except ValueError as exc:
            raise ChatClientError(f"{self.base_url}: decoding response: {exc}") from exc

        usage = response_body.get("usage") or {}
        cached = (usage.get("prompt_tokens_details") or {}).get("cached_tokens")
        logger.info(
            "chat completion: model=%s prompt_tokens=%s completion_tokens=%s cached_tokens=%s",
            self.model,
            usage.get("prompt_tokens"),
            usage.get("completion_tokens"),
            cached,
        )

        try:
            content = response_body["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError) as exc:
            raise ChatClientError(f"{self.base_url}: unexpected response shape: {exc}") from exc

        # response_format: json_schema returned clean, fence-free JSON in
        # every real probe against this endpoint — this strip is a
        # defensive fallback for a deployment/config that still wraps
        # output in a ```json ... ``` fence, not the expected case.
        stripped = content.strip()
        if stripped.startswith("```"):
            stripped = stripped.strip("`")
            if stripped.startswith("json"):
                stripped = stripped[4:]
            stripped = stripped.strip()

        try:
            return json.loads(stripped)
        except ValueError as exc:
            raise ChatClientError(f"{self.base_url}: response content is not valid JSON: {exc}") from exc


def chat_client_for(settings: Settings) -> ChatClient:
    """Builds the ChatClient from Settings — the one shared construction
    path, mirroring embedding_client.embedding_client_for."""
    return ChatClient(base_url=settings.chat_base_url, model=settings.chat_model, token=settings.chat_token)
