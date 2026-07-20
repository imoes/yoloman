"""Block G9-P3c — the auto-discovery run. A check is relevant only if running
it FOR REAL (normal mode) returns actual data (state OK/WARN/CRIT); the
`_discover` mode is then used for its item/metric shape. Pure orchestration
over the AgentClient interface, tested with a fake client; no live agent."""

import pytest

from bossman.services.discovery import run_check_discovery


class FakeClient:
    """Answers call_tool twice per check: normal mode `{}` returns a canned
    state (the relevance probe), `{_discover: True}` returns canned items.
    `states` maps check name -> probe state (default 'OK'); a name in
    `fail_names` raises on any call."""

    def __init__(self, discovery: dict, states: dict | None = None, fail_names: set | None = None):
        self._discovery = discovery
        self._states = states or {}
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
        short = name.split(".")[-1]
        if body.get("_discover"):
            return {"changed": False, "msg": "ok", "data": {"discovery": self._discovery.get(short, [])}}
        # normal-mode relevance probe
        return {"changed": False, "msg": "ok", "data": {"state": self._states.get(short, "OK")}}


def _check(name, options=None):
    return {"name": name, "fqcn": "checks." + name, "star": "def main(ctx, params): return {}\n",
            "sidecar": "name: " + name, "sidecar_format": "yaml",
            "options": options or {}, "short_description": name + " check"}


async def test_discovery_keeps_only_hosts_with_real_data():
    checks = [_check("df"), _check("uptime"), _check("apache")]
    disc = {
        "df": [{"item": "/", "params": {"warn": 80}, "metrics": ["used_percent"]},
               {"item": "/data", "params": {"warn": 80}, "metrics": ["used_percent"]}],
        "uptime": [{"item": "", "params": {}, "metrics": ["uptime"]}],
    }
    # apache's data source isn't here -> normal probe returns UNKNOWN -> dropped.
    client = FakeClient(disc, states={"df": "OK", "uptime": "OK", "apache": "UNKNOWN"})
    proposals = await run_check_discovery(client, checks)

    by_name = {p.check_name: p for p in proposals}
    assert set(by_name) == {"df", "uptime"}          # apache probed UNKNOWN -> not applicable
    assert [i.item for i in by_name["df"].items] == ["/", "/data"]
    assert by_name["df"].items[0].metrics == ["used_percent"]
    # Discovery-first (Checkmk model): _discover runs first; apache finds no
    # items, so it falls back to a normal probe, which returns UNKNOWN -> dropped.
    assert ("checks.apache", {"_discover": True}) in client.calls
    assert ("checks.apache", {}) in client.calls  # empty-discovery fallback probe
    # df found items via _discover, so it needs no fallback probe.
    assert ("checks.df", {}) not in client.calls


async def test_placeholder_discovery_dropped_when_data_absent():
    # The reported bug: mongodb_asserts-style checks whose `_discover` returns a
    # HARDCODED item without touching the host. On a host with no MongoDB the
    # real probe is UNKNOWN → the check must be dropped, not surfaced.
    client = FakeClient(
        {"mongodb_asserts": [{"item": "", "params": {}, "metrics": ["assert_user"]}]},
        states={"mongodb_asserts": "UNKNOWN"},
    )
    proposals = await run_check_discovery(client, [_check("mongodb_asserts")])
    assert proposals == []
    # it was verified with a real probe (not left on _discover's word)
    assert ("checks.mongodb_asserts", {}) in client.calls


async def test_relevant_check_with_empty_discovery_gets_a_default_item():
    # data present (OK) but the check enumerates nothing -> one default item.
    client = FakeClient({"ntp": []}, states={"ntp": "OK"})
    proposals = await run_check_discovery(client, [_check("ntp")])
    assert len(proposals) == 1 and proposals[0].items[0].item == ""


async def test_discovery_needs_params_from_required_no_default():
    checks = [_check("mysql", options={
        "user": {"type": "str", "required": True},          # -> needs param
        "port": {"type": "int", "required": True, "default": 3306},  # has default -> not needed
        "timeout": {"type": "int"},
    })]
    client = FakeClient({"mysql": [{"item": "", "params": {}, "metrics": ["connections"]}]}, states={"mysql": "WARN"})
    proposals = await run_check_discovery(client, checks)
    assert proposals[0].needs_params == ["user"]


async def test_probe_error_drops_the_check_without_sinking_run():
    checks = [_check("good"), _check("bad")]
    client = FakeClient({"good": [{"item": "x", "params": {}, "metrics": []}]},
                        states={"good": "OK"}, fail_names={"checks.bad"})
    proposals = await run_check_discovery(client, checks)
    by_name = {p.check_name: p for p in proposals}
    assert by_name["good"].items[0].item == "x"
    assert "bad" not in by_name          # a check that errored on probe is skipped, not raised


async def test_push_failure_surfaces_on_all():
    class PushFails(FakeClient):
        async def push_modules(self, modules):
            raise RuntimeError("push down")

    proposals = await run_check_discovery(PushFails({}), [_check("df")])
    assert proposals[0].error.startswith("push failed")


async def test_empty_checks_is_noop():
    assert await run_check_discovery(FakeClient({}), []) == []
