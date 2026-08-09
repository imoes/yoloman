"""Blueprints — compose native + docker services, wire them by capability, and
compile the whole stack into a typed playbook.

A blueprint's `services` mirror the UI compose model. compile_blueprint resolves
each service's `requires` against the other services' `provides` (the same
capability tokens the native sidecars + docker templates carry), threads the
provider's address into the consumer's config, orders by depends_on, and emits a
runbook doc (nt_runbook shape: per-service package→config_template→service for
native, a docker-run step for docker). seed_blueprint_drafts installs a few
ready-to-view drafts.
"""

from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.config import Settings
from bossman.db.models import DEFAULT_TENANT_ID, Blueprint
from bossman.services.capabilities import expand_backends


def _topo_order(services: list[dict]) -> list[dict]:
    """depends_on topo-sort (stable; cycles fall back to input order)."""
    by_name = {s["name"]: s for s in services}
    done: list[str] = []
    seen: set[str] = set()

    def visit(name: str, stack: set[str]) -> None:
        if name in seen or name not in by_name or name in stack:
            return
        stack.add(name)
        for dep in by_name[name].get("depends_on", []) or []:
            visit(dep, stack)
        stack.discard(name)
        seen.add(name)
        done.append(name)

    for s in services:
        visit(s["name"], set())
    return [by_name[n] for n in done]


def _address_of(svc: dict) -> str:
    """A service's in-stack address: docker → its compose name; native → its
    host if set, else a ${name}_host placeholder the deploy step resolves."""
    if svc.get("kind") == "docker":
        return svc["name"]
    return svc.get("host") or f"${{{svc['name']}_host}}"


def resolve_wiring(settings: Settings, services: list[dict]) -> tuple[list[dict], list[dict]]:
    """For each service's requires, find an in-blueprint provider (capability +
    backend match) and record the wiring; return (wiring, unresolved)."""
    wiring: list[dict] = []
    unresolved: list[dict] = []
    for consumer in services:
        for req in consumer.get("requires", []) or []:
            cap = req.get("capability")
            backends = expand_backends(settings, req.get("backends") or [])
            provider = None
            for p in services:
                if p is consumer:
                    continue
                for prov in p.get("provides", []) or []:
                    if prov.get("capability") == cap and (not backends or prov.get("backend") in backends):
                        provider = (p, prov)
                        break
                if provider:
                    break
            if provider is None:
                unresolved.append({"consumer": consumer["name"], "capability": cap, "backends": list(backends)})
                continue
            psvc, prov = provider
            fields = req.get("fields") or {}
            addr = _address_of(psvc)
            entry = {"consumer": consumer["name"], "provider": psvc["name"], "capability": cap,
                     "backend": prov.get("backend"), "set": {}}
            if fields.get("host"):
                entry["set"][fields["host"]] = addr
            if fields.get("port") and fields["port"] != fields.get("host") and prov.get("default_port"):
                entry["set"][fields["port"]] = prov["default_port"]
            wiring.append(entry)
    return wiring, unresolved


def _docker_run_step(svc: dict, wired_env: dict[str, Any]) -> dict:
    env = {**(svc.get("environment") or {}), **wired_env}
    parts = ["docker", "run", "-d", "--name", svc["name"], "--restart", "unless-stopped"]
    for k, v in env.items():
        parts += ["-e", f"{k}={v}"]
    for p in svc.get("ports", []) or []:
        parts += ["-p", f"{p}:{p}"]
    parts.append(svc.get("image") or svc["name"])
    return {"name": f"Deploy container {svc['name']}", "module": "shell",
            "args": {"cmd": " ".join(str(x) for x in parts)}}


def _native_steps(svc: dict, wired_vals: dict[str, Any]) -> list[dict]:
    template = svc.get("template") or svc.get("role") or svc["name"]
    role = svc.get("role") or svc["name"]
    vals = {**(svc.get("values") or {}), **wired_vals}
    return [
        {"name": f"Install {role}", "module": "package", "args": {"name": role, "state": "present"}},
        {"name": f"Configure {role}", "module": "config_template",
         "args": {"template": template, "dest": f"/etc/{role}/{role}.conf", "vars": vals}},
        {"name": f"Enable and start {role}", "module": "service",
         "args": {"name": role, "state": "restarted", "enabled": True}, "ignore_errors": True},
    ]


def _template_of(svc: dict) -> str:
    """The config template a native service's config_template step references —
    kept in one place so validation and the emitted step agree."""
    return svc.get("template") or svc.get("role") or svc["name"]


def compile_blueprint(
    settings: Settings, bp: Blueprint, known_templates: set[str] | None = None,
) -> dict[str, Any]:
    """Compile a blueprint into a typed playbook + a wiring/order report. Pure.

    `known_templates` (the set of real config_template names) lets the compile
    flag native services whose template doesn't exist — the same check the
    runbook linter/whatif does, surfaced at design time so a draft can't be
    saved referencing a template that isn't there. None skips the check.
    """
    services = list(bp.services or [])
    wiring, unresolved = resolve_wiring(settings, services)
    # Index wiring by consumer for env/vals injection.
    by_consumer: dict[str, dict] = {}
    for w in wiring:
        by_consumer.setdefault(w["consumer"], {}).update(w["set"])

    ordered = _topo_order(services)
    steps: list[dict] = []
    warnings: list[dict] = []
    for svc in ordered:
        injected = by_consumer.get(svc["name"], {})
        if svc.get("kind") == "docker":
            steps.append(_docker_run_step(svc, injected))
        else:
            tpl = _template_of(svc)
            if known_templates is not None and tpl not in known_templates:
                warnings.append({"service": svc["name"], "kind": "unknown_template", "template": tpl,
                                 "message": f"config template {tpl!r} does not exist"})
            steps.extend(_native_steps(svc, injected))

    playbook = {
        "kind": "runbook",
        "name": f"blueprint-{bp.name}".lower().replace(" ", "-"),
        "targets": None,
        "parameters": {},
        "steps": steps,
    }
    return {
        "playbook": playbook,
        "order": [s["name"] for s in ordered],
        "wiring": wiring,
        "unresolved": unresolved,
        "warnings": warnings,
    }


# --- Seed drafts ------------------------------------------------------------

def _svc(name, kind, **kw) -> dict:
    return {"name": name, "kind": kind, "environment": {}, "values": {}, "ports": [],
            "depends_on": [], "provides": [], "requires": [], **kw}


_DRAFTS: list[dict] = [
    {
        "name": "WordPress stack (docker)",
        "description": "WordPress + MariaDB, wired by capability (WP requires database → MariaDB provides it).",
        "services": [
            _svc("db", "docker", image="mariadb", ports=["3306"],
                 environment={"MARIADB_DATABASE": "wordpress", "MARIADB_USER": "wp", "MARIADB_PASSWORD": "wp-secret",
                              "MARIADB_ROOT_PASSWORD": "root-secret"},
                 provides=[{"capability": "database", "backend": "mariadb", "default_port": 3306}]),
            _svc("wordpress", "docker", image="wordpress", ports=["80"], depends_on=["db"],
                 environment={"WORDPRESS_DB_USER": "wp", "WORDPRESS_DB_PASSWORD": "wp-secret", "WORDPRESS_DB_NAME": "wordpress"},
                 requires=[{"capability": "database", "backends": ["mysql", "mariadb"],
                            "fields": {"host": "WORDPRESS_DB_HOST"}}]),
        ],
    },
    {
        "name": "Monitoring stack (docker)",
        "description": "Prometheus + Grafana; Grafana requires metrics → Prometheus provides them.",
        "services": [
            _svc("prometheus", "docker", image="prom/prometheus", ports=["9090"],
                 provides=[{"capability": "metrics", "backend": "prometheus", "default_port": 9090}]),
            _svc("grafana", "docker", image="grafana/grafana", ports=["3000"], depends_on=["prometheus"],
                 requires=[{"capability": "metrics", "backends": ["prometheus"],
                            "fields": {"host": "GF_METRICS_HOST", "port": "GF_METRICS_HOST"}}]),
        ],
    },
    {
        "name": "LAMP (native)",
        "description": "Native Apache web server + MariaDB database on the same host, wired by capability.",
        "services": [
            _svc("mariadb", "native", role="mariadb", template="50-server.cnf",
                 provides=[{"capability": "database", "backend": "mariadb", "default_port": 3306}]),
            _svc("apache2", "native", role="apache2", template="apache2", depends_on=["mariadb"],
                 requires=[{"capability": "database", "backends": ["mysql", "mariadb"],
                            "fields": {"host": "db_host", "port": "db_port"}}],
                 provides=[{"capability": "web_server", "backend": "apache", "default_port": 80}]),
        ],
    },
    {
        "name": "Reverse-proxied app (mixed)",
        "description": "Native nginx reverse proxy in front of a docker app (nginx requires an upstream web_server).",
        "services": [
            _svc("app", "docker", image="nginx", ports=["8080"],
                 provides=[{"capability": "web_server", "backend": "nginx", "default_port": 8080}]),
            _svc("proxy", "native", role="nginx", template="nginx-core", depends_on=["app"],
                 requires=[{"capability": "web_server", "backends": ["nginx", "apache", "php", "node", "caddy"],
                            "fields": {"host": "upstream_host", "port": "upstream_port"}}],
                 provides=[{"capability": "reverse_proxy", "backend": "nginx", "default_port": 80}]),
        ],
    },
]


async def seed_blueprint_drafts(session: AsyncSession) -> int:
    """Insert the sample blueprint drafts that don't exist yet. Returns count."""
    added = 0
    for d in _DRAFTS:
        exists = await session.scalar(select(Blueprint.id).where(Blueprint.name == d["name"]))
        if exists:
            continue
        session.add(Blueprint(
            tenant_id=DEFAULT_TENANT_ID, name=d["name"], description=d["description"],
            status="draft", services=d["services"], created_by="seed",
        ))
        added += 1
    return added
