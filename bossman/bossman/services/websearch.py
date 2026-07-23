"""SearXNG web-search client.

A thin async wrapper over the SearXNG JSON API (co-located with the LLM host,
see Settings.searxng_base_url) plus a best-effort page fetcher that strips HTML
to plain text. Used by the package-doc verification batch (qwen reads official
documentation to check a role's template/runbook for completeness) and exposed
as the web_search / fetch_url MCP tools.

Deliberately dependency-light: httpx (already a dep) + a regex HTML stripper, so
it works inside the headless batch with no extra packages. SearXNG lives on the
internal network, so requests must NOT go through the corporate proxy — callers
run with no_proxy covering .example.internal (the batch supervisor already does).
"""

from __future__ import annotations

import re
from dataclasses import dataclass

import httpx


@dataclass
class SearchResult:
    title: str
    url: str
    content: str  # SearXNG's snippet/summary for the hit

    def to_dict(self) -> dict[str, str]:
        return {"title": self.title, "url": self.url, "content": self.content}


_TAG_RE = re.compile(r"<[^>]+>")
_SCRIPT_RE = re.compile(r"<(script|style)\b[^>]*>.*?</\1>", re.IGNORECASE | re.DOTALL)
_WS_RE = re.compile(r"[ \t\r\f\v]+")
_BLANKS_RE = re.compile(r"\n\s*\n\s*\n+")


def html_to_text(html: str) -> str:
    """Strip HTML to readable plain text (drop script/style, unwrap tags,
    collapse whitespace). Good enough to feed documentation pages to an LLM."""
    text = _SCRIPT_RE.sub(" ", html)
    text = re.sub(r"</(p|div|li|tr|h[1-6]|br|pre|section)>", "\n", text, flags=re.IGNORECASE)
    text = _TAG_RE.sub("", text)
    # Common HTML entities that survive tag-stripping.
    for ent, ch in (("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&"), ("&quot;", '"'),
                    ("&#39;", "'"), ("&nbsp;", " ")):
        text = text.replace(ent, ch)
    text = _WS_RE.sub(" ", text)
    text = _BLANKS_RE.sub("\n\n", text)
    return text.strip()


class SearxngClient:
    """One SearXNG endpoint. Search returns ranked hits; fetch returns a page's
    plain text (truncated). Best-effort: network/HTTP errors surface as
    exceptions the caller decides how to tolerate."""

    def __init__(self, base_url: str, timeout: float = 20.0) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    # SearXNG's default engine set on this instance is entirely suspended
    # (brave/duckduckgo/google/startpage → CAPTCHA, rate-limit, access-denied),
    # so an unqualified query returns ZERO results. These engines answer
    # reliably from here — pin them explicitly or every search comes back empty.
    DEFAULT_ENGINES = "bing,mojeek,wikipedia"

    async def search(self, query: str, limit: int = 6,
                     engines: str | None = None) -> list[SearchResult]:
        """Run a SearXNG search and return up to `limit` results."""
        params = {"q": query, "format": "json",
                  "engines": engines or self.DEFAULT_ENGINES}
        # trust_env=True: honour the environment's proxy config. SearXNG is
        # internal, so no_proxy (which must cover .example.internal) keeps this hit
        # direct; the fetched documentation pages below are EXTERNAL and do need
        # the corporate proxy — the same env serves both correctly.
        async with httpx.AsyncClient(timeout=self.timeout, trust_env=True,
                                     follow_redirects=True) as client:
            resp = await client.get(f"{self.base_url}/search", params=params)
            resp.raise_for_status()
            data = resp.json()
        out: list[SearchResult] = []
        for r in data.get("results", [])[:limit]:
            out.append(SearchResult(
                title=(r.get("title") or "").strip(),
                url=(r.get("url") or "").strip(),
                content=(r.get("content") or "").strip(),
            ))
        return out

    async def fetch(self, url: str, max_chars: int = 12000) -> str:
        """Fetch a URL and return its plain text, truncated to max_chars."""
        async with httpx.AsyncClient(timeout=self.timeout, trust_env=True,
                                     follow_redirects=True,
                                     headers={"User-Agent": "bossman-docs/1.0"}) as client:
            resp = await client.get(url)
            resp.raise_for_status()
            ctype = resp.headers.get("content-type", "")
            body = resp.text
        text = html_to_text(body) if "html" in ctype or "<html" in body[:2000].lower() else body
        return text[:max_chars]
