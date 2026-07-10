"""Block G9-P3c — the auto-discovery run (push checks + invoke _discover +
collect items). Pure orchestration over the AgentClient interface, tested
with a fake client; no live agent."""

import pytest

from bossman.services.discovery import run_check_discovery


class FakeClient:
    """Records pushes and answers call_tool(name, {_discover}) from a canned
    per-check discovery map."""

    def __init__(self, discovery: dict, fail_names: set | None = None):
        self._discovery = discovery
        self._fail = fail_names or set()
        self.pushed: list[str] = []
        self.calls: list[tuple[str, dict]] = []

    async def push_modules(self, modules):
        self.pushed = [m["fqcn"] for m in modules]
        return {"results": [{"fqcn": m["fqcn"], "ok": True} for m in modules]}

    async def call_tool(self, name, body):
        self.calls.append((name, body))
        if name in self._fail:
            raise RuntimeError("boom " + name)
        items = self._discovery.get(name, [])
        return {"changed": False, "msg": "ok", "data": {"discovery": items}}


def _check(name, options=None):
    return {"name": name, "star": "def main(ctx, params): return {}\n", "sidecar": "name: " + name,
            "sidecar_format": "yaml", "options": options or {}, "short_description": name + " check"}


async def test_discovery_collects_items_and_metrics():
    checks = [_check("df"), _check("uptime"), _check("apache")]
    disc = {
        "df": [{"item": "/", "params": {"warn": 80}, "metrics": ["used_percent"]},
               {"item": "/data", "params": {"warn": 80}, "metrics": ["used_percent"]}],
        "uptime": [{"item": "", "params": {}, "metrics": ["uptime"]}],
        "apache": [],  # not running here -> no items -> dropped from proposals
    }
    client = FakeClient(disc)
    proposals = await run_check_discovery(client, checks)

    # all three pushed with dotted fqcn; discovery mode invoked on each
    assert client.pushed == ["checks.df", "checks.uptime", "checks.apache"]
    assert all(body == {"_discover": True} for _, body in client.calls)

    by_name = {p.check_name: p for p in proposals}
    assert "apache" not in by_name          # discovered nothing -> not applicable
    assert set(by_name) == {"df", "uptime"}
    assert [i.item for i in by_name["df"].items] == ["/", "/data"]
    assert by_name["df"].items[0].metrics == ["used_percent"]
    assert by_name["uptime"].items[0].item == ""


async def test_discovery_needs_params_from_required_no_default():
    checks = [_check("mysql", options={
        "user": {"type": "str", "required": True},          # -> needs param
        "port": {"type": "int", "required": True, "default": 3306},  # has default -> not needed
        "timeout": {"type": "int"},
    })]
    client = FakeClient({"mysql": [{"item": "", "params": {}, "metrics": ["connections"]}]})
    proposals = await run_check_discovery(client, checks)
    assert proposals[0].needs_params == ["user"]


async def test_discovery_reports_per_check_error_without_sinking_run():
    checks = [_check("good"), _check("bad")]
    client = FakeClient({"good": [{"item": "x", "params": {}, "metrics": []}]}, fail_names={"bad"})
    proposals = await run_check_discovery(client, checks)
    by_name = {p.check_name: p for p in proposals}
    assert by_name["good"].items[0].item == "x"
    assert by_name["bad"].error and not by_name["bad"].items   # errored check surfaced, not raised


async def test_push_failure_surfaces_on_all():
    class PushFails(FakeClient):
        async def push_modules(self, modules):
            raise RuntimeError("push down")

    proposals = await run_check_discovery(PushFails({}), [_check("df")])
    assert proposals[0].error.startswith("push failed")


async def test_empty_checks_is_noop():
    assert await run_check_discovery(FakeClient({}), []) == []
