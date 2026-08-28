"""Offline tests for the Phase-2 autonomy guardrail gate (DB-free short-circuits)."""
import asyncio
from types import SimpleNamespace
import pytest
from bossman.services import remediation as rem


class _NoDB:
    """A session that must never be touched — proves the gate short-circuits
    BEFORE any DB call (rate-limit) on the safety-critical paths."""
    def __getattr__(self, _n): raise AssertionError("DB must not be hit on this path")


def _pol(**kw):
    d = dict(enabled=True, autonomy="auto_verify", allow_prod=False, max_per_hour=3,
             max_blast_radius=1, id="p1")
    d.update(kw); return SimpleNamespace(**d)


def test_is_prod():
    assert rem._is_prod(SimpleNamespace(criticality="prod", tags={}))
    assert rem._is_prod(SimpleNamespace(criticality=None, tags={"env": "production"}))
    assert not rem._is_prod(SimpleNamespace(criticality="low", tags={"env": "test"}))


def _gate(settings, policy, agent, counts=None):
    return asyncio.run(rem._auto_allowed(_NoDB(), settings, policy, agent, counts or {}))


def test_kill_switch_blocks():
    ok, reason = _gate(SimpleNamespace(remediation_autonomy_enabled=False), _pol(),
                       SimpleNamespace(criticality="low", tags={}))
    assert not ok and "kill-switch" in reason


def test_non_autonomous_policy_blocks():
    ok, reason = _gate(SimpleNamespace(remediation_autonomy_enabled=True), _pol(autonomy="propose"),
                       SimpleNamespace(criticality="low", tags={}))
    assert not ok and "not autonomous" in reason


def test_prod_host_blocks_without_allow_prod():
    ok, reason = _gate(SimpleNamespace(remediation_autonomy_enabled=True), _pol(allow_prod=False),
                       SimpleNamespace(criticality="prod", tags={}))
    assert not ok and "production" in reason
