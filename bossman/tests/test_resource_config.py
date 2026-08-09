"""Tests for ConfigResource — the native-config tier as a DELEGATING adapter:
every verb goes to the agent state store (no Bossman generation store), so there
is one config history (the agent's, host-scoped)."""
from __future__ import annotations

import types

import pytest

from bossman.services.resources.config_file import ConfigResource

PATH = "/etc/app.conf"


class _FakeStateClient:
    def __init__(self):
        self.applied = None
        self.rolled_back = None

    async def state_observed(self):
        return {"observed": {"config": [
            {"path": PATH, "format": "keyvalue", "separator": "=", "values": {"a": "1", "b": "2"}},
            {"path": "/etc/other", "format": "ini", "values": {}},
        ]}}

    async def state_plan(self, document):
        # echo a change for our path
        return {"changes": [{"path": PATH, "action": "update", "changed": {"a": ["1", "9"]}}], "changed_count": 1}

    async def state_apply(self, document, dry_run):
        self.applied = (document, dry_run)
        return {"plan": {"changed_count": 1}, "generation": 7}

    async def state_generations(self):
        return {"generations": [
            {"number": 7, "applied_at": "2026-07-26T00:00:00Z", "hash": "abc", "resources": 3},
            {"number": 6, "applied_at": "2026-07-25T00:00:00Z", "hash": "def", "resources": 3},
        ]}

    async def state_rollback(self, generation, dry_run):
        self.rolled_back = (generation, dry_run)
        return {"plan": {"changed_count": 2}, "generation": 8}


def _res():
    client = _FakeStateClient()
    agent = types.SimpleNamespace(id="a1", name="docker-test")
    r = ConfigResource(session=object(), agent=agent, client_factory=lambda a, s: client, settings=None, path=PATH)
    return r, client


@pytest.mark.asyncio
async def test_observe_finds_this_path():
    r, _ = _res()
    obs = await r.observe()
    assert obs["path"] == PATH and obs["format"] == "keyvalue" and obs["values"] == {"a": "1", "b": "2"}
    assert r.resource_key == f"config:a1:{PATH}"


@pytest.mark.asyncio
async def test_plan_extracts_change_for_path():
    r, _ = _res()
    p = await r.plan({"values": {"a": "9", "b": "2"}})
    assert p["action"] == "update" and p["changed"] == {"a": ["1", "9"]}
    assert p["delegated_to"] == "agent.state"


@pytest.mark.asyncio
async def test_apply_delegates_and_keeps_format_from_observed():
    r, client = _res()
    out = await r.apply({"values": {"a": "9"}}, dry_run=False)
    assert out["ok"] and out["generation"] == 7 and out["generation_scope"] == "host"
    # the resource doc carried the file's real format/separator (from observe)
    doc, dry = client.applied
    res = doc["resources"][0]
    assert res["type"] == "config" and res["format"] == "keyvalue" and res["separator"] == "=" and dry is False


@pytest.mark.asyncio
async def test_generations_are_host_scoped_from_agent():
    r, _ = _res()
    gens = await r.generations()
    assert [g["generation"] for g in gens] == [7, 6]
    assert "host-scoped" in gens[0]["note"]


@pytest.mark.asyncio
async def test_rollback_delegates_to_agent_state():
    r, client = _res()
    out = await r.rollback(6)
    assert out["ok"] and out["generation"] == 8 and out["generation_scope"] == "host"
    assert client.rolled_back == (6, False)


# --- per-directive schema + flat↔nested round-trip (the truthful-schema work) ---

INI_PATH = "/etc/systemd/journald.conf"


class _IniStateClient(_FakeStateClient):
    """A SECTIONED (ini) file, plus a codec-less one — the shapes that make the
    flat-key/index question real."""

    async def state_observed(self):
        return {"observed": {"config": [
            {"path": INI_PATH, "format": "ini",
             "values": {"Journal": {"Storage": "auto", "Audit": "yes"}}},
            {"path": "/etc/opaque", "format": "", "sha256": "deadbeef"},   # no codec
        ]}}

    async def state_plan(self, document):
        self.planned = document          # capture what the agent would receive
        return {"changes": [{"path": INI_PATH, "action": "update",
                             "before": {"Journal": {"Storage": "auto", "Audit": "yes"}},
                             "after": {"Journal": {"Storage": "persistent", "Audit": "yes"}},
                             "changed": {}}],          # agent reports section-level
                "changed_count": 1}


def _ini_res():
    client = _IniStateClient()
    agent = types.SimpleNamespace(id="a1", name="docker-test")
    return ConfigResource(session=object(), agent=agent, client_factory=lambda a, s: client,
                          settings=None, path=INI_PATH), client


@pytest.mark.asyncio
async def test_schema_is_one_field_per_directive_not_a_values_blob():
    r, _ = _res()
    schema = await r.schema_async()
    assert set(schema) == {"a", "b"}                     # the file's real keys
    assert "values" not in schema and "path" not in schema and "format" not in schema
    assert r.schema() == schema                          # sync half serves the cache


@pytest.mark.asyncio
async def test_schema_flattens_ini_sections():
    r, _ = _ini_res()
    schema = await r.schema_async()
    assert set(schema) == {"Journal.Storage", "Journal.Audit"}
    assert schema["Journal.Storage"]["key_path"] == ["Journal", "Storage"]


@pytest.mark.asyncio
async def test_schema_empty_without_codec():
    client = _IniStateClient()
    agent = types.SimpleNamespace(id="a1", name="docker-test")
    r = ConfigResource(session=object(), agent=agent, client_factory=lambda a, s: client,
                       settings=None, path="/etc/opaque")
    assert await r.schema_async() == {}                  # honest: no form, not a fake blob


@pytest.mark.asyncio
async def test_observe_adds_flat_values():
    r, _ = _ini_res()
    obs = await r.observe()
    assert obs["values"] == {"Journal": {"Storage": "auto", "Audit": "yes"}}   # unchanged
    assert obs["flat_values"] == {"Journal.Storage": "auto", "Journal.Audit": "yes"}


@pytest.mark.asyncio
async def test_plan_accepts_flat_values_and_sends_nested_doc():
    """The critical one: the form posts dotted keys, the agent must receive the
    file's real nested structure."""
    r, client = _ini_res()
    await r.plan({"values": {"Journal.Storage": "persistent", "Journal.Audit": "yes"}})
    sent = client.planned["resources"][0]
    assert sent["values"] == {"Journal": {"Storage": "persistent", "Audit": "yes"}}
    assert sent["format"] == "ini"


@pytest.mark.asyncio
async def test_plan_changed_is_per_directive_not_section_blob():
    r, _ = _ini_res()
    out = await r.plan({"values": {"Journal.Storage": "persistent"}})
    assert out["changed"] == {"Journal.Storage": ["auto", "persistent"]}
    assert out["changed_raw"] == {}                      # what the agent reported


@pytest.mark.asyncio
async def test_plan_still_accepts_already_nested_values():
    r, client = _ini_res()
    await r.plan({"values": {"Journal": {"Storage": "persistent"}}})
    assert client.planned["resources"][0]["values"] == {"Journal": {"Storage": "persistent"}}
