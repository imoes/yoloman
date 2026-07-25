"""Tests for the rehearsal plane (Block 5) — a System's docker members are
deployed for real in a sandbox, health-gated (docker inspect .State), and torn
down; the report passes only when every member is running and healthy."""
from __future__ import annotations

import json
import types

import pytest

from bossman.services import system_rehearsal


def _system(*apps_images):
    members = [types.SimpleNamespace(target="docker", app=a, config={"image": img}) for a, img in apps_images]
    return types.SimpleNamespace(id="s1", name="demo", members=members)


class _FakeClient:
    """Records docker commands; returns a scripted .State per container name."""
    def __init__(self, states):
        self.states = states          # {container_name: state dict}
        self.calls = []

    async def call_tool(self, name, args):
        argv = args["argv"]
        self.calls.append(argv)
        if argv[:2] == ["docker", "inspect"]:
            cname = argv[-1]
            return {"data": {"rc": 0, "stdout": json.dumps(self.states.get(cname, {})), "stderr": ""}}
        # deploy (sh -c "... docker run ...") and rm succeed
        return {"data": {"rc": 0, "stdout": "", "stderr": ""}}


@pytest.mark.asyncio
async def test_rehearse_passes_when_all_running(monkeypatch):
    target = types.SimpleNamespace(id="t1", name="staging")
    client = _FakeClient({
        "sbx-demo-web": {"Running": True, "Status": "running"},              # no healthcheck → healthy-by-default
        "sbx-demo-db": {"Running": True, "Status": "running", "Health": {"Status": "healthy"}},
    })
    sys = _system(("web", "nginx:1.27"), ("db", "postgres:16"))
    out = await system_rehearsal.rehearse(sys, target, lambda a, s: client, settings=None, settle_seconds=0)

    assert out["passed"] is True
    assert set(out["torn_down"]) == {"sbx-demo-web", "sbx-demo-db"}
    # a rm was issued for each sandbox container (teardown)
    rms = [c for c in client.calls if c[:3] == ["docker", "rm", "-f"]]
    assert len(rms) == 2


@pytest.mark.asyncio
async def test_rehearse_fails_when_a_member_unhealthy(monkeypatch):
    target = types.SimpleNamespace(id="t1", name="staging")
    client = _FakeClient({
        "sbx-demo-web": {"Running": True, "Status": "running"},
        "sbx-demo-db": {"Running": False, "Status": "exited"},               # crashed
    })
    sys = _system(("web", "nginx:1.27"), ("db", "postgres:16"))
    out = await system_rehearsal.rehearse(sys, target, lambda a, s: client, settings=None, settle_seconds=0)
    assert out["passed"] is False
    db = [c for c in out["checks"] if c.get("container") == "sbx-demo-db"][0]
    assert db["passed"] is False and db["running"] is False


@pytest.mark.asyncio
async def test_rehearse_applies_image_override():
    target = types.SimpleNamespace(id="t1", name="staging")
    client = _FakeClient({"sbx-demo-web": {"Running": True, "Status": "running"}})
    sys = _system(("web", "nginx:1.27"))
    out = await system_rehearsal.rehearse(sys, target, lambda a, s: client, settings=None,
                                          image_overrides={"web": "nginx:1.29"}, settle_seconds=0)
    assert out["passed"] is True and out["change"] == {"image_overrides": {"web": "nginx:1.29"}}
    # the deploy sh -c command carried the override image
    deploy_cmds = [" ".join(c) for c in client.calls if c[0] == "sh"]
    assert any("nginx:1.29" in c for c in deploy_cmds)


@pytest.mark.asyncio
async def test_rehearse_no_docker_members():
    target = types.SimpleNamespace(id="t1", name="staging")
    sys = types.SimpleNamespace(id="s1", name="demo",
                                members=[types.SimpleNamespace(target="native", app="nginx", config={})])
    out = await system_rehearsal.rehearse(sys, target, lambda a, s: None, settings=None)
    assert "error" in out
