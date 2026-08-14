"""The Resource contract, enforced.

docs/resource-protocol.md claims "the contract is identical across kinds". Nothing
checked that claim, so nobody would have noticed a kind that renames a verb, forgets
one, or grows a private quirk — the observation point docs/logik-audit.md found
missing. These tests iterate the registry and hold every kind to its declaration.
"""
from __future__ import annotations

import inspect

import pytest

from bossman.services import resources as reg


def test_registry_lists_every_kind_the_api_exposes():
    # The kinds are the legal URL segment values; keep this list explicit so adding a
    # kind to the registry without deciding on its URL name fails here.
    assert reg.kinds() == ["config", "docker", "helm", "package", "role", "service"]


@pytest.mark.parametrize("kind", reg.kinds())
def test_every_kind_implements_the_verbs_it_declares(kind: str):
    spec = reg.spec_for(kind)
    for verb in spec.verbs:
        assert hasattr(spec.cls, verb), f"{spec.cls.__name__} declares {verb!r} but does not implement it"


@pytest.mark.parametrize("kind", reg.kinds())
def test_state_changing_verbs_are_async(kind: str):
    """observe/plan/apply/rollback talk to a host, so they must be awaitable. `schema`
    is pure data and stays synchronous — that asymmetry is intentional and therefore
    asserted, not left to chance."""
    spec = reg.spec_for(kind)
    for verb in ("observe", "plan", "apply", "rollback"):
        fn = getattr(spec.cls, verb)
        assert inspect.iscoroutinefunction(fn), f"{spec.cls.__name__}.{verb} must be async"
    if spec.has_schema:
        assert not inspect.iscoroutinefunction(spec.cls.schema)


@pytest.mark.parametrize("kind", reg.kinds())
def test_every_kind_names_itself(kind: str):
    spec = reg.spec_for(kind)
    assert getattr(spec.cls, "resource_type", ""), f"{spec.cls.__name__} has no resource_type"
    assert spec.label, f"{kind} has no human label"


def test_config_is_the_documented_exception():
    """`config` is the one kind that breaks the uniform shape, and it must break it in
    exactly the declared way — addressed by path, and no schema verb. The UI used to
    guess this and guessed wrong (it built a /schema URL that does not exist)."""
    cfg = reg.spec_for("config")
    assert cfg.addressed_by == "path"
    assert cfg.has_schema is False
    assert "schema" not in cfg.verbs
    # every OTHER kind is addressed by a name segment and does have a schema
    for kind in reg.kinds():
        if kind == "config":
            continue
        s = reg.spec_for(kind)
        assert s.addressed_by == "name", f"{kind} deviates without declaring it"
        assert s.has_schema is True
        assert "schema" in s.verbs


def test_history_verbs_are_part_of_the_contract_for_every_kind():
    """A resource without generations cannot be rolled back — the gap the protocol was
    written to close. No kind may opt out."""
    for kind in reg.kinds():
        assert set(reg.HISTORY_VERBS) <= set(reg.spec_for(kind).verbs)


def test_quirks_are_declared_where_they_belong():
    assert reg.spec_for("helm").query_params == ("namespace",)
    assert reg.spec_for("role").extra_verbs == ("binding",)
    assert reg.spec_for("role").needs_identity is True
    # and nowhere else, so a quirk cannot spread unnoticed
    for kind in ("docker", "config", "package", "service"):
        s = reg.spec_for(kind)
        assert s.query_params == () and s.extra_verbs == () and s.needs_identity is False


def test_unknown_kind_error_names_the_alternatives():
    """A refusal that does not say what would have been accepted is a refusal without a
    reason."""
    with pytest.raises(ValueError) as e:
        reg.spec_for("nope")
    msg = str(e.value)
    assert "nope" in msg
    for kind in reg.kinds():
        assert kind in msg


@pytest.mark.parametrize("kind", reg.kinds())
def test_declared_schema_flavour_matches_the_class(kind: str):
    """`schema_is_async` is a claim about the class — check it against the class, or the
    declaration is just a second place to be wrong."""
    spec = reg.spec_for(kind)
    if not spec.has_schema:
        return
    if spec.schema_is_async:
        assert hasattr(spec.cls, "schema_async"), f"{spec.cls.__name__} declares an async schema but has no schema_async()"
        assert inspect.iscoroutinefunction(spec.cls.schema_async)
    else:
        assert not inspect.iscoroutinefunction(spec.cls.schema)


def test_which_kinds_state_their_schema_statically():
    """Asserted exhaustively so a new kind cannot quietly join either group. docker,
    package and service can describe themselves without asking anyone; helm and role
    must look at the DB/host first (config has no schema route at all)."""
    static = [k for k in reg.kinds() if reg.spec_for(k).has_schema and not reg.spec_for(k).schema_is_async]
    derived = [k for k in reg.kinds() if reg.spec_for(k).has_schema and reg.spec_for(k).schema_is_async]
    assert static == ["docker", "package", "service"]
    assert derived == ["helm", "role"]


def test_role_is_the_only_kind_that_works_without_a_host_address():
    """A role binding is DB-only desired state, so a PLANNED host can be given roles
    before it boots. Every other kind talks to the host and needs an address."""
    no_addr = [k for k in reg.kinds() if not reg.spec_for(k).needs_address]
    assert no_addr == ["role"]


def test_config_is_the_only_kind_with_response_quirks():
    """config carries its schema in observe() and labels its history with a scope."""
    with_schema_in_observe = [k for k in reg.kinds() if reg.spec_for(k).observe_includes_schema]
    with_scope = [k for k in reg.kinds() if reg.spec_for(k).generations_scope]
    assert with_schema_in_observe == ["config"]
    assert with_scope == ["config"]
    assert reg.spec_for("config").generations_scope == "host"


def test_as_dict_is_plain_data_for_the_ui():
    d = reg.as_dict()
    assert set(d) == set(reg.kinds())
    assert d["config"]["has_schema"] is False and d["config"]["addressed_by"] == "path"
    assert "namespace" in d["helm"]["query_params"]
    # the newly declared quirks must reach the UI too, or it goes back to guessing
    assert d["docker"]["schema_is_async"] is False and d["helm"]["schema_is_async"] is True
    assert d["role"]["needs_address"] is False
    assert d["config"]["observe_includes_schema"] is True
    assert d["config"]["generations_scope"] == "host"
