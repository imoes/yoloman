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

import asyncio
import json
import logging
from typing import TYPE_CHECKING

import httpx

if TYPE_CHECKING:
    from bossman.config import Settings

logger = logging.getLogger(__name__)

# A shared llama.cpp endpoint (qwen79b) evicts/reloads its model under other
# tenants' demand, so a request frequently gets a fast 503 "Loading model" (or a
# 502/504 from the gateway) while the model cold-loads. These are transient: the
# model IS coming back, typically within a couple of minutes. Retry with backoff
# instead of failing the item — a 503 returns in milliseconds, so the wait, not
# the request, dominates, and once the model is warm the real completion goes
# through. A genuine 4xx (bad request/auth) is NOT retried.
_RETRY_STATUSES = frozenset({502, 503, 504})
_MAX_ATTEMPTS = 8
_BASE_DELAY = 10.0  # seconds; grows per attempt, capped at _MAX_DELAY
_MAX_DELAY = 30.0


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

    async def _post(self, body: dict) -> dict:
        """POST to the chat-completions endpoint and return the decoded
        response body, retrying transient failures (a reloading model → 503,
        gateway 502/504, or a network blip) with backoff. Raises
        ChatClientError on a non-retryable status, a decode failure, or after
        exhausting retries."""
        url = f"{self.base_url}/v1/chat/completions"
        last = "no attempt made"
        for attempt in range(_MAX_ATTEMPTS):
            try:
                async with self._client() as client:
                    resp = await client.post(url, json=body)
            except httpx.HTTPError as exc:
                last = f"request failed: {exc}"
            else:
                if resp.status_code == 200:
                    try:
                        return resp.json()
                    except ValueError as exc:
                        raise ChatClientError(f"{self.base_url}: decoding response: {exc}") from exc
                if resp.status_code not in _RETRY_STATUSES:
                    raise ChatClientError(f"{self.base_url}: unexpected status {resp.status_code}: {resp.text[:4096]}")
                last = f"status {resp.status_code}: {resp.text[:200]}"
            if attempt < _MAX_ATTEMPTS - 1:
                delay = min(_BASE_DELAY * (attempt + 1), _MAX_DELAY)
                logger.warning(
                    "%s: transient (%s); retry %d/%d in %.0fs",
                    self.base_url, last, attempt + 1, _MAX_ATTEMPTS - 1, delay,
                )
                await asyncio.sleep(delay)
        raise ChatClientError(f"{self.base_url}: giving up after {_MAX_ATTEMPTS} attempts: {last}")

    async def complete_json(
        self,
        messages: list[dict[str, str]],
        json_schema: dict,
        schema_name: str,
        max_tokens: int | None = 4000,
    ) -> dict:
        """Sends a chat-completion request constrained to json_schema and
        returns the decoded response content as a dict. Raises
        ChatClientError on any network/status/decode failure — never
        returns a partial or best-effort result.

        Pass max_tokens=None to omit the cap entirely (server default / no
        limit) — use for open-ended generation that must not be truncated."""
        body = {
            "model": self.model,
            "messages": messages,
            "response_format": {"type": "json_schema", "json_schema": {"name": schema_name, "schema": json_schema}},
        }
        if max_tokens is not None:
            body["max_tokens"] = max_tokens
        response_body = await self._post(body)

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

    async def complete_text(
        self,
        messages: list[dict[str, str]],
        max_tokens: int = 8000,
        extra_body: dict | None = None,
    ) -> str:
        """Plain chat completion returning the raw assistant text — used
        when the payload is a single code blob (a Starlark module, see
        docs/plan.md Block G8), where a JSON-schema envelope only forces
        the model to escape every newline/quote of the code into a string
        and buys nothing. `extra_body` is merged into the request body
        (e.g. {"chat_template_kwargs": {"enable_thinking": False}} to turn
        a Qwen reasoning model's thinking off so it emits the answer
        directly instead of burning the budget in reasoning_content).
        Raises ChatClientError on any failure or an empty completion."""
        body: dict = {"model": self.model, "messages": messages, "max_tokens": max_tokens}
        if extra_body:
            body.update(extra_body)
        response_body = await self._post(body)
        try:
            choice = response_body["choices"][0]
            content = choice["message"]["content"]
        except (KeyError, IndexError, TypeError) as exc:
            raise ChatClientError(f"{self.base_url}: unexpected response shape: {exc}") from exc

        usage = response_body.get("usage") or {}
        logger.info(
            "chat completion (text): model=%s prompt_tokens=%s completion_tokens=%s finish=%s",
            self.model,
            usage.get("prompt_tokens"),
            usage.get("completion_tokens"),
            choice.get("finish_reason"),
        )
        if not content or not content.strip():
            # An empty content with a non-stop finish reason is the
            # signature of a reasoning model that spent its whole budget
            # thinking — surface it explicitly rather than as "empty code".
            raise ChatClientError(
                f"{self.base_url}: empty completion (finish_reason={choice.get('finish_reason')}) — "
                "if this is a reasoning model, disable thinking or raise max_tokens"
            )
        return content


def chat_client_for(settings: Settings) -> ChatClient:
    """Builds the ChatClient from Settings — the one shared construction
    path, mirroring embedding_client.embedding_client_for."""
    return ChatClient(base_url=settings.chat_base_url, model=settings.chat_model, token=settings.chat_token)
