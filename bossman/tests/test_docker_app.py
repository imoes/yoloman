"""Unit tests for the docker tier's observe side — `docker inspect` JSON parsed
into a portable, re-appliable container spec (the SAME shape deploy_container
consumes) plus its docker-compose provenance from labels."""
from __future__ import annotations

import json
import types

import pytest

from bossman.services.docker_app import _parse_inspect, inspect_containers

INSPECT_OBJ = {
    "Name": "/web",
    "Config": {
        "Image": "nginx:1.27",
        "Env": ["PATH=/usr/bin", "NGINX_HOST=example.local"],
        "Labels": {
            "com.docker.compose.project": "shop",
            "com.docker.compose.service": "web",
            "com.docker.compose.project.config_files": "/srv/shop/docker-compose.yml",
        },
    },
    "HostConfig": {
        "RestartPolicy": {"Name": "unless-stopped"},
        "Binds": ["/srv/shop/html:/usr/share/nginx/html:ro"],
        "PortBindings": {"80/tcp": [{"HostPort": "8080"}], "443/tcp": [{"HostPort": "8443"}]},
    },
}


def test_parse_inspect_recovers_portable_spec():
    spec = _parse_inspect(INSPECT_OBJ)
    assert spec["name"] == "web"                 # leading slash stripped
    assert spec["image"] == "nginx:1.27"
    assert spec["restart"] == "unless-stopped"
    assert spec["env"] == {"PATH": "/usr/bin", "NGINX_HOST": "example.local"}
    assert spec["volumes"] == ["/srv/shop/html:/usr/share/nginx/html:ro"]
    assert {"host": "8080", "container": "80"} in spec["ports"]
    assert {"host": "8443", "container": "443"} in spec["ports"]
    # docker-compose provenance flows into the desired state
    assert spec["compose_project"] == "shop"
    assert spec["compose_service"] == "web"
    assert spec["compose_file"] == "/srv/shop/docker-compose.yml"


def test_parse_inspect_non_compose_container():
    spec = _parse_inspect({"Name": "/solo", "Config": {"Image": "redis"}, "HostConfig": {}})
    assert spec["name"] == "solo"
    assert spec["image"] == "redis"
    assert spec["restart"] == "no"       # no RestartPolicy → default
    assert spec["ports"] == [] and spec["env"] == {} and spec["volumes"] == []
    assert spec["compose_file"] is None  # not compose-managed


class _FakeClient:
    def __init__(self, stdout: str):
        self._stdout = stdout

    async def call_tool(self, name, args):
        assert name == "command"
        return {"data": {"rc": 0, "stdout": self._stdout, "stderr": ""}}


@pytest.mark.asyncio
async def test_inspect_containers_parses_and_lists_compose_files():
    agent = types.SimpleNamespace(id="a1", name="docker-test")
    client = _FakeClient(json.dumps([INSPECT_OBJ, {"Name": "/solo", "Config": {"Image": "redis"}, "HostConfig": {}}]))
    out = await inspect_containers(agent, lambda a, s: client, settings=None)
    assert out["count"] == 2
    assert out["compose_files"] == ["/srv/shop/docker-compose.yml"]
    assert {c["name"] for c in out["containers"]} == {"web", "solo"}


@pytest.mark.asyncio
async def test_inspect_containers_empty_host():
    agent = types.SimpleNamespace(id="a1", name="docker-test")
    out = await inspect_containers(agent, lambda a, s: _FakeClient("[]"), settings=None)
    assert out["count"] == 0 and out["compose_files"] == []
