"""A small in-process cache for the entire parsed plan catalog (see
docs/plan.md's Bossman plan: the original prompt-caching design plus its
later chunked-plan-caching refinement).

Before this, only the rendered catalog text was cached — every other
consumer (`list_plans`, `run_plan`, and every REST plan route) called
`load_plans_dir()` fresh on every single call, re-parsing every plan YAML
file from disk each time. This cache parses once, at construction and on
explicit `reload()` (`POST /api/v1/plans/reload`, see bossman/api/plans.py)
— never per request — and every consumer reads from it instead.
"""

from __future__ import annotations

from bossman.services.plan_loader import Plan, load_plans_dir, render_catalog_markdown


def _plan_list_json(plan: Plan) -> dict:
    return {
        "name": plan.name,
        "description": plan.description,
        "params": {
            name: {"type": spec.type, "required": spec.required, "default": spec.default}
            for name, spec in plan.params.items()
        },
    }


class CatalogCache:
    def __init__(self, plans_dir: str):
        self._plans_dir = plans_dir
        self._rebuild()

    def _rebuild(self) -> None:
        self._plans: list[Plan] = load_plans_dir(self._plans_dir)
        self._by_name: dict[str, Plan] = {p.name: p for p in self._plans}
        self._list_json: list[dict] = [_plan_list_json(p) for p in self._plans]
        self._catalog_markdown: str = render_catalog_markdown(self._plans)

    @property
    def plans(self) -> list[Plan]:
        """Every parsed Plan, in load_plans_dir's sorted order — for
        consumers (the REST API) that need the full Plan object, not just
        its MCP-facing JSON shape (e.g. a param's `pattern`, which
        list_json intentionally omits since the MCP tool catalog doesn't
        need it)."""
        return self._plans

    def get(self, name: str) -> Plan | None:
        return self._by_name.get(name)

    @property
    def list_json(self) -> list[dict]:
        """The exact shape the MCP `list_plans` tool and any other
        machine-facing consumer wants — computed once, not per call."""
        return self._list_json

    @property
    def catalog_markdown(self) -> str:
        """The static, cacheable Markdown catalog block — byte-identical
        across calls until reload() runs (see render_catalog_markdown's
        own docstring for why Markdown, not JSON, and why the host is
        never part of this text)."""
        return self._catalog_markdown

    def reload(self) -> str:
        self._rebuild()
        return self._catalog_markdown
