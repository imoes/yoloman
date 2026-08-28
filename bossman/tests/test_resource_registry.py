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


# ---------------------------------------------------------------------------
# The builder: one call shape for every kind, and the read verbs' response
# shapes. Doubles stand in for the session/agent so these run without a host
# or a database — the DB-backed tests cannot run from here at all
# (docs/logik-audit.md area 9), so the contract has to be checkable offline.
# ---------------------------------------------------------------------------

class _FakeAgent:
    def __init__(self, name="h1", address="10.0.0.1"):
        self.name = name
        self.address = address


class _FakeSession:
    """Returns whatever agent it was given for any session.get(Agent, id)."""
    def __init__(self, agent):
        self._agent = agent

    async def get(self, _model, _pk):
        return self._agent


def _spy_cls(recorder, *, plan_row=object()):
    """A stand-in resource that records how it was constructed."""
    class _Spy:
        resource_key = "spy:key"
        resource_type = "spy"

        def __init__(self, session, agent, client_factory, settings, name, **kw):
            recorder.update(session=session, agent=agent, name=name, kwargs=kw)

        def schema(self):
            return {"sync": True}

        async def schema_async(self):
            return {"async": True}

        async def observe(self):
            return {"observed": True}

        async def generations(self):
            return [{"generation": 1}]

        async def _plan_row(self):
            return plan_row

    return _Spy


@pytest.mark.asyncio
async def test_build_refuses_an_unknown_host_with_a_reason():
    with pytest.raises(reg.NoSuchResource) as e:
        await reg.build("docker", agent_id="x", name="n", session=_FakeSession(None),
                        settings=None, client_factory=None)
    assert "no such agent" in str(e.value)


@pytest.mark.asyncio
async def test_build_refuses_an_unreachable_host_for_kinds_that_need_one(monkeypatch):
    rec: dict = {}
    monkeypatch.setitem(reg.REGISTRY, "docker",
                        reg.ResourceSpec(kind="docker", cls=_spy_cls(rec), schema_is_async=False))
    with pytest.raises(reg.ResourceUnreachable) as e:
        await reg.build("docker", agent_id="x", name="n",
                        session=_FakeSession(_FakeAgent(address="")), settings=None, client_factory=None)
    assert "no reachable address" in str(e.value)


@pytest.mark.asyncio
async def test_role_builds_for_a_host_without_an_address(monkeypatch):
    """The declared exception, exercised: a planned host that never booted can still be
    given a role, because the binding is DB-only desired state."""
    rec: dict = {}
    monkeypatch.setitem(reg.REGISTRY, "role",
                        reg.ResourceSpec(kind="role", cls=_spy_cls(rec), needs_address=False,
                                         needs_identity=True))

    class _Id:
        name = "alice"

    r = await reg.build("role", agent_id="x", name="web", session=_FakeSession(_FakeAgent(address="")),
                        settings=None, client_factory=None, identity=_Id())
    assert r is not None
    assert rec["kwargs"]["requested_by"] == "alice"


@pytest.mark.asyncio
async def test_role_missing_plan_row_says_what_a_role_is(monkeypatch):
    rec: dict = {}
    monkeypatch.setitem(reg.REGISTRY, "role",
                        reg.ResourceSpec(kind="role", cls=_spy_cls(rec, plan_row=None),
                                         needs_address=False, needs_identity=True))
    with pytest.raises(reg.NoSuchResource) as e:
        await reg.build("role", agent_id="x", name="web", session=_FakeSession(_FakeAgent()),
                        settings=None, client_factory=None)
    msg = str(e.value)
    assert "no such role" in msg and "OrchestrationPlan" in msg   # the reason, not just the refusal


@pytest.mark.asyncio
async def test_helm_gets_its_namespace_and_defaults_it(monkeypatch):
    rec: dict = {}
    monkeypatch.setitem(reg.REGISTRY, "helm",
                        reg.ResourceSpec(kind="helm", cls=_spy_cls(rec), query_params=("namespace",)))
    await reg.build("helm", agent_id="x", name="rel", session=_FakeSession(_FakeAgent()),
                    settings=None, client_factory=None, namespace="prod")
    assert rec["kwargs"]["namespace"] == "prod"
    await reg.build("helm", agent_id="x", name="rel", session=_FakeSession(_FakeAgent()),
                    settings=None, client_factory=None)
    assert rec["kwargs"]["namespace"] == "default"


@pytest.mark.asyncio
async def test_read_verb_shapes_match_what_callers_already_get(monkeypatch):
    rec: dict = {}
    # a kind with a synchronous schema and no quirks
    monkeypatch.setitem(reg.REGISTRY, "docker",
                        reg.ResourceSpec(kind="docker", cls=_spy_cls(rec), schema_is_async=False))
    spy = _spy_cls(rec)(None, None, None, None, "n")
    assert await reg.read_verb("docker", "schema", spy) == {
        "resource_key": "spy:key", "type": "spy", "schema": {"sync": True}}
    assert await reg.read_verb("docker", "observe", spy) == {
        "resource_key": "spy:key", "observed": {"observed": True}}
    assert await reg.read_verb("docker", "generations", spy) == {
        "resource_key": "spy:key", "generations": [{"generation": 1}]}


@pytest.mark.asyncio
async def test_config_keeps_its_two_response_quirks(monkeypatch):
    rec: dict = {}
    monkeypatch.setitem(reg.REGISTRY, "config",
                        reg.ResourceSpec(kind="config", cls=_spy_cls(rec), addressed_by="path",
                                         has_schema=False, observe_includes_schema=True,
                                         generations_scope="host"))
    spy = _spy_cls(rec)(None, None, None, None, "/etc/x")
    obs = await reg.read_verb("config", "observe", spy)
    assert obs["schema"] == {"async": True} and obs["observed"] == {"observed": True}
    gens = await reg.read_verb("config", "generations", spy)
    assert gens["scope"] == "host"
    # and it has no schema endpoint — asking for one says why
    with pytest.raises(reg.NoSuchResource) as e:
        await reg.read_verb("config", "schema", spy)
    assert "arrives with observe()" in str(e.value)


@pytest.mark.asyncio
async def test_read_verb_rejects_a_write_verb():
    with pytest.raises(ValueError) as e:
        await reg.read_verb("docker", "apply", object())
    assert "not a read verb" in str(e.value)
