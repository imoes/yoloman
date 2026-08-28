"""The Resource registry — the single place that says what kinds exist and how each
one differs from the others.

`docs/resource-protocol.md` promises ONE interface with four verbs and states that
"the contract is identical across kinds". Until now nothing enforced that: this
package's `__init__` was empty, `api/resources.py` wrote the six verb families out by
hand once per kind (36 routes), and the per-kind quirks were discoverable only by
reading the duplicated routes — the UI even re-implemented one of them twice (see
docs/logik-audit.md, area 7).

So the differences are DECLARED here instead:

* `addressed_by` — how an instance is identified. Everything is addressed by a `name`
  path segment except `config`, whose instance is a filesystem path and therefore
  travels in the request body (a path cannot ride in a URL segment unescaped).
* `has_schema` — whether the kind can describe its fields. `config` cannot: its
  schema depends on the file's codec, so it arrives with `observe()` instead.
* `query_params` — extra identity that is not part of the path (Helm's `namespace`).
* `extra_verbs` — sub-resources beyond the four (role's `binding`, which can be
  DELETEd).
* `needs_identity` — the kind acts on behalf of a user (role bindings are audited).

A registry entry is a *description*, not a factory: construction still differs per
kind (some builders take an agent id, some an agent object, Helm takes a namespace,
role takes the identity) and is unified in a later step. Declaring the shape first is
what makes the contract testable at all — `tests/test_resource_registry.py` iterates
this table and checks every kind against it, which is the observation point the audit
found missing.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from bossman.services.resources.config_file import ConfigResource
from bossman.services.resources.docker_container import DockerContainerResource
from bossman.services.resources.helm_release import HelmReleaseResource
from bossman.services.resources.package_resource import PackageResource
from bossman.services.resources.role import RoleResource
from bossman.services.resources.service_resource import ServiceResource

class NoSuchResource(LookupError):
    """The host or the instance does not exist → the API answers 404.

    A service raising its own exception (instead of FastAPI's HTTPException) keeps the
    dependency pointing one way: the API may know about services, services must not
    know about HTTP. The message is written for a human, because the API passes it
    straight through as the reason.
    """


class ResourceUnreachable(RuntimeError):
    """The host exists but cannot be reached directly → the API answers 422."""


#: The four verbs every kind must implement, plus the two history verbs that make a
#: change reversible. `generations`/`rollback` are part of the contract because a
#: resource without history cannot be rolled back — that was the original complaint
#: ("docker has no generations") the protocol set out to fix.
CORE_VERBS = ("schema", "observe", "plan", "apply")
HISTORY_VERBS = ("generations", "rollback")


@dataclass(frozen=True)
class ResourceSpec:
    """What one kind is, and every way it deviates from the uniform contract."""

    kind: str
    cls: type
    #: 'name' → /resources/{kind}/{name}/{verb}; 'path' → identified in the body.
    addressed_by: str = "name"
    has_schema: bool = True
    #: Query parameters that co-identify the instance (not part of the path).
    query_params: tuple[str, ...] = ()
    #: Sub-resources beyond the verbs, e.g. ("binding",) for role.
    extra_verbs: tuple[str, ...] = ()
    #: True when the operation is performed on behalf of a user and audited.
    needs_identity: bool = False
    #: Whether the host must have a reachable address. `role` deliberately does NOT:
    #: a role binding is DB-only desired state, so a PLANNED (not yet booted) host can
    #: be given roles now and converge when it first checks in. Demanding an address
    #: there would forbid a legitimate case — the quirk is declared, not buried in a
    #: route body (api/resources.py's _role_resource explains the same thing).
    needs_address: bool = True
    #: Whether the kind derives its schema from live data (`schema_async()`) or states
    #: it statically (`schema()`). docker/package/service are static; helm/role/config
    #: must ask the host or the DB first. A caller has to know which — and the test
    #: checks this against the class, because a declaration that nobody verifies is
    #: just a second place to be wrong (it caught this very field being wrong once).
    schema_is_async: bool = True
    #: `config` returns its field schema together with `observe()`, because the schema
    #: depends on the file's codec and is computed from the observed values anyway.
    observe_includes_schema: bool = False
    #: `config` labels its history with the scope it applies to ("host").
    generations_scope: str | None = None
    #: Human wording used by the UI and the docs — one label per kind, everywhere.
    label: str = ""
    notes: str = ""

    @property
    def verbs(self) -> tuple[str, ...]:
        """Every verb this kind actually answers — `schema` drops out for `config`."""
        core = tuple(v for v in CORE_VERBS if v != "schema" or self.has_schema)
        return core + HISTORY_VERBS


#: kind → spec. The kind string is what appears in the URL and in the UI's
#: `ResourceKind`, so this table is also the list of legal values.
REGISTRY: dict[str, ResourceSpec] = {
    "docker": ResourceSpec(
        kind="docker", cls=DockerContainerResource, label="Docker container",
        schema_is_async=False,
        notes="One container's desired spec (image, ports, env, volumes, restart).",
    ),
    "helm": ResourceSpec(
        kind="helm", cls=HelmReleaseResource, label="Helm release",
        query_params=("namespace",),
        notes="A release is identified by name AND namespace, so namespace is a query param.",
    ),
    "config": ResourceSpec(
        kind="config", cls=ConfigResource, label="Config file",
        addressed_by="path", has_schema=False, observe_includes_schema=True,
        generations_scope="host",
        notes="Addressed by filesystem path in the body, not a URL segment. Its field "
              "schema depends on the file's codec and therefore arrives with observe(); "
              "its history is labelled with the scope it applies to.",
    ),
    "role": ResourceSpec(
        kind="role", cls=RoleResource, label="Role binding",
        extra_verbs=("binding",), needs_identity=True, needs_address=False,
        notes="Binding a role is done on behalf of a user and audited; DELETE .../binding "
              "removes the link. Needs NO host address: the binding is DB-only desired "
              "state, so a planned host can be given roles before it ever boots.",
    ),
    "package": ResourceSpec(
        kind="package", cls=PackageResource, label="OS package",
        schema_is_async=False,
        notes="present/absent/version of one package.",
    ),
    "service": ResourceSpec(
        kind="service", cls=ServiceResource, label="systemd unit",
        schema_is_async=False,
        notes="enabled/state of one unit.",
    ),
}


async def build(kind: str, *, agent_id, name: str, session, settings, client_factory,
                identity=None, **query):
    """Construct the resource for one instance — the ONE place that knows how the kinds
    differ in construction.

    Before this, each kind had its own factory with its own signature (agent id vs
    agent object, Helm's namespace, role's identity), which is why the routes could not
    be shared. The differences are read from the spec now, so a caller passes the same
    arguments for every kind.

    Raises NoSuchResource / ResourceUnreachable — never an HTTP exception.
    """
    from bossman.db.models import Agent

    spec = spec_for(kind)
    agent = await session.get(Agent, agent_id)
    if agent is None:
        raise NoSuchResource(f"no such agent {agent_id}")
    # `role` is the declared exception: a binding is DB-only desired state, so a host
    # that has never booted may still be given roles (see the spec's notes).
    if spec.needs_address and not agent.address:
        raise ResourceUnreachable(f"agent {agent.name!r} has no reachable address")

    if spec.kind == "helm":
        return spec.cls(session, agent, client_factory, settings, name,
                        namespace=query.get("namespace") or "default")
    if spec.kind == "role":
        r = spec.cls(session, agent, client_factory, settings, name,
                     requested_by=getattr(identity, "name", "resource-api"))
        # 404 here rather than failing deeper down: a role is an OrchestrationPlan of
        # type 'role', and saying so is more useful than an error from three layers in.
        if await r._plan_row() is None:
            raise NoSuchResource(
                f"no such role: {name!r} — a role is an OrchestrationPlan of type 'role' "
                "(author it in Ansible task syntax under a `role:` key and compile via "
                "POST /api/v1/runbooks/role/compile)")
        return r
    # docker, config (name IS the file path), package, service
    return spec.cls(session, agent, client_factory, settings, name)


async def read_verb(kind: str, verb: str, resource) -> dict[str, Any]:
    """Run one of the READ verbs and shape the response exactly as this kind's callers
    already receive it. The per-kind response quirks come from the spec instead of from
    duplicated route bodies:

    * `schema` — `schema_async()` when the kind derives it from live data, else `schema()`
    * `observe` — `config` returns its field schema alongside the values
    * `generations` — `config` labels its history with the scope it applies to
    """
    spec = spec_for(kind)
    if verb == "schema":
        if not spec.has_schema:
            raise NoSuchResource(f"{kind} has no schema endpoint — its schema arrives with observe()")
        schema = await resource.schema_async() if spec.schema_is_async else resource.schema()
        return {"resource_key": resource.resource_key, "type": resource.resource_type, "schema": schema}
    if verb == "observe":
        out: dict[str, Any] = {"resource_key": resource.resource_key}
        if spec.observe_includes_schema:
            # schema first: it derives the per-directive fields from the observed values
            # (and caches the flatten index observe() needs anyway).
            out["schema"] = await resource.schema_async()
        out["observed"] = await resource.observe()
        return out
    if verb == "generations":
        out = {"resource_key": resource.resource_key}
        if spec.generations_scope:
            out["scope"] = spec.generations_scope
        out["generations"] = await resource.generations()
        return out
    raise ValueError(f"{verb!r} is not a read verb — expected schema, observe or generations")


def spec_for(kind: str) -> ResourceSpec:
    """The spec for a kind, or a ValueError naming the legal values.

    Raising with the alternatives listed is deliberate: a refusal that does not say
    what would have been accepted is a refusal without a reason.
    """
    try:
        return REGISTRY[kind]
    except KeyError:
        raise ValueError(
            f"unknown resource kind {kind!r} — expected one of: {', '.join(sorted(REGISTRY))}"
        ) from None


def kinds() -> list[str]:
    return sorted(REGISTRY)


def as_dict() -> dict[str, dict[str, Any]]:
    """The registry as plain data — so the UI can derive its capabilities instead of
    hard-coding them (today both UI clients guessed, and one guessed wrong: it built a
    `/schema` URL for `config`, which does not exist)."""
    return {
        s.kind: {
            "kind": s.kind, "label": s.label, "addressed_by": s.addressed_by,
            "has_schema": s.has_schema, "verbs": list(s.verbs),
            "query_params": list(s.query_params), "extra_verbs": list(s.extra_verbs),
            "needs_identity": s.needs_identity, "needs_address": s.needs_address,
            "schema_is_async": s.schema_is_async,
            "observe_includes_schema": s.observe_includes_schema,
            "generations_scope": s.generations_scope, "notes": s.notes,
        }
        for s in REGISTRY.values()
    }


READ_VERBS = ("schema", "observe", "generations")

__all__ = [
    "CORE_VERBS", "HISTORY_VERBS", "READ_VERBS", "REGISTRY", "NoSuchResource",
    "ResourceSpec", "ResourceUnreachable", "as_dict", "build", "kinds", "read_verb",
    "spec_for",
]
