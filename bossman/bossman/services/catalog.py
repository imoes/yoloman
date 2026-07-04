"""A small in-process cache for the plan catalog's rendered text (see
docs/plan.md's Bossman plan, section B.6): Anthropic prompt caching needs
a byte-identical prefix across calls to actually hit the cache, so the
catalog text handed to an LLM client must not be re-rendered on every
call — only when explicitly asked to reload (POST /api/v1/plans/reload,
see bossman/api/plans.py), never per-request.
"""

from __future__ import annotations

from bossman.services.plan_loader import render_catalog_text


class CatalogCache:
    def __init__(self, plans_dir: str):
        self._plans_dir = plans_dir
        self._text = render_catalog_text(plans_dir)

    @property
    def text(self) -> str:
        return self._text

    def reload(self) -> str:
        self._text = render_catalog_text(self._plans_dir)
        return self._text
