"""Tests for cross-tier materialize: a portable spec's resources are split by
type — native config → the agent state store (generations/rollback), docker
containers → docker deploy — and dry-run previews both without writing."""
from __future__ import annotations

import types

import pytest

from bossman.services.server_reproduce import materialize_spec

SPEC = {
    "source": {"id": "src", "name": "prod"},
    "resources": [
        {"type": "config", "path": "/etc/app.conf", "format": "keyvalue", "separator": "=",
         "values": {"a": "1"}},
        {"type": "docker_container", "name": "web", "image": "nginx:1.27",
         "ports": [{"host": "8080", "container": "80"}], "env": {"X": "1"},
         "volumes": [], "restart": "unless-stopped", "compose_file": "/srv/dc.yml"},
    ],
}


class _FakeClient:
    def __init__(self):
        self.state_apply_args = None

    async def state_apply(self, doc, dry_run):
        self.state_apply_args = (doc, dry_run)
        return {"plan": {"changed_count": 1}, "generation": 5}


@pytest.mark.asyncio
async def test_materialize_splits_config_and_docker_dry_run():
    target = types.SimpleNamespace(id="t1", name="staging")
    client = _FakeClient()
    out = await materialize_spec(None, target, lambda a, s: client, settings=None, spec=SPEC, dry_run=True)

    # config resource went to state_apply (and ONLY the config resource)
    doc, dry = client.state_apply_args
    assert dry is True
    assert [r["type"] for r in doc["resources"]] == ["config"]
    assert out["changed_count"] == 1 and out["generation"] == 5

    # docker container previewed as a docker run command, not executed
    assert out["docker_count"] == 1
    d = out["docker"][0]
    assert d["name"] == "web"
    assert "docker run" in d["command"] and "nginx:1.27" in d["command"]
    assert "-p 8080:80" in d["command"]
    assert d.get("ok") is None   # dry-run → not actually deployed


@pytest.mark.asyncio
async def test_materialize_native_only_spec():
    target = types.SimpleNamespace(id="t1", name="staging")
    client = _FakeClient()
    spec = {"resources": [SPEC["resources"][0]]}
    out = await materialize_spec(None, target, lambda a, s: client, settings=None, spec=spec, dry_run=True)
    assert out["changed_count"] == 1
    assert "docker" not in out   # no docker resources → no docker section
