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


__all__ = ["CORE_VERBS", "HISTORY_VERBS", "REGISTRY", "ResourceSpec", "as_dict", "kinds", "spec_for"]
