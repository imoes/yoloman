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
from bossman.services.capabilities import expand_backends, load_vocabulary


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


def _connection_fields(settings: Settings, capability: str) -> list[str]:
    """The canonical connection-field roles for a capability, from the vocabulary
    (e.g. database → host, port, name, user, password, socket)."""
    caps = load_vocabulary(settings).get("capabilities") or {}
    return list((caps.get(capability) or {}).get("connection_fields") or [])


def _targets_of(req: dict) -> dict:
    """The consumer's field map (canonical field role → its env/value key). New
    blueprints use `field_targets`; older ones used `fields` (host/port only)."""
    return req.get("field_targets") or req.get("fields") or {}


def _service_source_value(field: str, spec: dict | None, psvc: dict, prov: dict) -> tuple[Any, bool]:
    """Resolve ONE connection field's value from an in-blueprint provider service.
    Returns (value, is_secret). `from`: address | port | const | env | value."""
    frm = (spec or {}).get("from")
    secret = bool((spec or {}).get("secret"))
    if frm == "const":
        return spec.get("value"), secret
    if frm == "env":
        return (psvc.get("environment") or {}).get(spec.get("key", "")), secret
    if frm == "value":
        return (psvc.get("values") or {}).get(spec.get("key", "")), secret
    if frm == "address":
        return _address_of(psvc), secret
    if frm == "port":
        return prov.get("default_port"), secret
    # No explicit source → sensible defaults for the universal fields.
    if field == "host":
        return _address_of(psvc), False
    if field == "port":
        return prov.get("default_port"), False
    return None, secret


def _provides_field_sources(prov: dict) -> dict:
    return prov.get("field_sources") or {}


def resolve_wiring(
    settings: Settings, services: list[dict], *, fleet_providers: dict | None = None,
) -> tuple[list[dict], list[dict]]:
    """For each consumer's requires, pick a provider (an in-blueprint service first,
    then a supplied fleet host) and map EVERY connection field the capability defines
    (host/port/name/user/password/…) from the provider's `field_sources` into the
    consumer's `field_targets`. Secrets are flagged (encoded to a vault handle at bind
    time). Returns (wiring, unresolved); unresolved carries a `reason` of
    "no_provider" or "missing_fields".

    `fleet_providers` maps a requirement key (`<consumer>#<capability>#<index>`) to a
    find_providers() dict, so the DB lookup stays in the API layer and this function
    remains pure/testable."""
    wiring: list[dict] = []
    unresolved: list[dict] = []
    fleet_providers = fleet_providers or {}
    for consumer in services:
        for i, req in enumerate(consumer.get("requires", []) or []):
            cap = req.get("capability")
            backends = expand_backends(settings, req.get("backends") or [])
            targets = _targets_of(req)
            fields = _connection_fields(settings, cap) or list(targets.keys())
            req_key = f"{consumer['name']}#{cap}#{i}"

            # 1) provider: an in-blueprint service whose provides matches …
            match = None
            for p in services:
                if p is consumer:
                    continue
                for prov in p.get("provides", []) or []:
                    if prov.get("capability") == cap and (not backends or prov.get("backend") in backends):
                        match = ("service", p, prov)
                        break
                if match:
                    break
            # … else a real fleet host the API resolved for this requirement.
            if match is None and req_key in fleet_providers:
                fp = fleet_providers[req_key]
                match = ("host", fp, fp.get("detail") or {})
            if match is None:
                unresolved.append({"consumer": consumer["name"], "capability": cap,
                                   "backends": list(backends), "reason": "no_provider"})
                continue

            entry: dict = {"consumer": consumer["name"], "capability": cap, "provider_kind": match[0],
                           "set": {}, "fields": {}, "secret_fields": [], "missing_fields": []}

            if match[0] == "service":
                _, psvc, prov = match
                entry["provider"] = psvc["name"]
                entry["backend"] = prov.get("backend")
                sources = _provides_field_sources(prov)
                for f in fields:
                    tgt = targets.get(f)
                    if not tgt:
                        continue  # consumer doesn't consume this field
                    val, secret = _service_source_value(f, sources.get(f), psvc, prov)
                    if val is None or val == "":
                        entry["missing_fields"].append(f)
                        continue
                    entry["set"][tgt] = val
                    entry["fields"][f] = tgt
                    if secret:
                        entry["secret_fields"].append(tgt)
            else:  # fleet host
                fp = match[1]
                detail = match[2] if isinstance(match[2], dict) else {}
                prov0 = (detail.get("provides") or [{}])[0] if isinstance(detail.get("provides"), list) else {}
                sources = prov0.get("field_sources") or detail.get("field_sources") or {}
                entry["provider"] = fp.get("hostname")
                entry["provider_agent_id"] = fp.get("agent_id")
                entry["backend"] = fp.get("backend")
                for f in fields:
                    tgt = targets.get(f)
                    if not tgt:
                        continue
                    if f == "host":
                        val, secret = fp.get("address"), False
                    elif f == "port":
                        val, secret = fp.get("port"), False
                    elif sources.get(f, {}).get("from") == "const":
                        val, secret = sources[f].get("value"), bool(sources[f].get("secret"))
                    else:
                        # user/password/name on an existing host need provisioning
                        # or a stored secret — flagged as missing for plausibility.
                        val, secret = None, False
                    if val is None or val == "":
                        entry["missing_fields"].append(f)
                        continue
                    entry["set"][tgt] = val
                    entry["fields"][f] = tgt
                    if secret:
                        entry["secret_fields"].append(tgt)

            wiring.append(entry)
            if entry["missing_fields"]:
                unresolved.append({"consumer": consumer["name"], "capability": cap,
                                   "provider": entry.get("provider"), "reason": "missing_fields",
                                   "fields": entry["missing_fields"]})
    return wiring, unresolved


def open_requirements_for_fleet(settings: Settings, services: list[dict]) -> list[dict]:
    """The requirements that have NO in-blueprint provider — the ones the API should
    look up against the fleet (host_capabilities). Returns dicts with the req_key so
    the resolved providers can be handed back to resolve_wiring()."""
    out: list[dict] = []
    for consumer in services:
        for i, req in enumerate(consumer.get("requires", []) or []):
            cap = req.get("capability")
            has_inbp = any(
                prov.get("capability") == cap
                for p in services if p is not consumer
                for prov in (p.get("provides", []) or [])
            )
            if has_inbp:
                continue
            out.append({"req_key": f"{consumer['name']}#{cap}#{i}", "consumer": consumer["name"],
                        "capability": cap, "backends": req.get("backends") or []})
    return out


def plausibility(settings: Settings, services: list[dict], fleet_providers: dict | None = None) -> dict:
    """Design-time validation of the whole stack: does every requirement resolve to a
    provider, and does that provider supply every connection field the consumer needs?
    Returns {ok, problems[], wiring, unresolved} — `ok` is false only on errors (a
    missing field is a warning, since credentials may be provisioned at deploy)."""
    wiring, unresolved = resolve_wiring(settings, services, fleet_providers=fleet_providers)
    problems: list[dict] = []
    for u in unresolved:
        if u.get("reason") == "no_provider":
            problems.append({"severity": "error", "consumer": u["consumer"], "capability": u["capability"],
                             "message": f"{u['consumer']} requires '{u['capability']}' but nothing provides it "
                                        "(no in-blueprint service and no matching fleet host)."})
        elif u.get("reason") == "missing_fields":
            problems.append({"severity": "warning", "consumer": u["consumer"], "capability": u["capability"],
                             "message": f"{u['consumer']}'s '{u['capability']}' connection is missing "
                                        f"{', '.join(u['fields'])} — provider '{u.get('provider')}' offers no "
                                        "source (author it on the provider, or provision at deploy)."})
    order = _topo_order(services)
    return {
        "ok": not any(p["severity"] == "error" for p in problems),
        "problems": problems,
        "wiring": wiring,
        "unresolved": unresolved,
        "order": [s["name"] for s in order],
        "resolved": len(wiring),
    }


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


def _apply_secret_policy(value: Any, is_secret: bool, vault: Any, mask: bool) -> Any:
    """A wired secret value → a vault handle (bind/deploy), a mask (preview), or
    left as-is. A value that is already a `vault:` handle is passed through."""
    if not is_secret or value in (None, ""):
        return value
    if isinstance(value, str) and value.startswith("vault:"):
        return value
    if vault is not None:
        return vault.encrypt(str(value))
    if mask:
        return "••••••••"
    return value


def compile_blueprint(
    settings: Settings, bp: Blueprint, known_templates: set[str] | None = None,
    *, fleet_providers: dict | None = None, vault: Any = None, mask_secrets: bool = False,
) -> dict[str, Any]:
    """Compile a blueprint into a typed playbook + a wiring/order report.

    `known_templates` flags native services whose config_template doesn't exist.
    `fleet_providers` (from the API's host_capabilities lookup) lets a requirement
    resolve against a real host, not only an in-blueprint service. Secret fields
    are protected per policy: `vault` → encrypt to a `vault:` handle (bind/deploy),
    else `mask_secrets` → mask them (safe preview response)."""
    services = list(bp.services or [])
    wiring, unresolved = resolve_wiring(settings, services, fleet_providers=fleet_providers)
    # Index wiring by consumer for env/vals injection, applying the secret policy.
    by_consumer: dict[str, dict] = {}
    for w in wiring:
        secret_keys = set(w.get("secret_fields") or [])
        dst = by_consumer.setdefault(w["consumer"], {})
        for k, v in w["set"].items():
            v2 = _apply_secret_policy(v, k in secret_keys, vault, mask_secrets)
            dst[k] = v2
            if k in secret_keys:
                w["set"][k] = v2  # reflect the policy in the returned report too

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
                 provides=[{"capability": "database", "backend": "mariadb", "default_port": 3306,
                            "field_sources": {
                                "host": {"from": "address"},
                                "port": {"from": "port"},
                                "name": {"from": "env", "key": "MARIADB_DATABASE"},
                                "user": {"from": "env", "key": "MARIADB_USER"},
                                "password": {"from": "env", "key": "MARIADB_PASSWORD", "secret": True}}}]),
            _svc("wordpress", "docker", image="wordpress", ports=["80"], depends_on=["db"],
                 requires=[{"capability": "database", "backends": ["mysql", "mariadb"],
                            "field_targets": {"host": "WORDPRESS_DB_HOST", "port": "WORDPRESS_DB_PORT",
                                              "name": "WORDPRESS_DB_NAME", "user": "WORDPRESS_DB_USER",
                                              "password": "WORDPRESS_DB_PASSWORD"}}]),
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
                 values={"db_name": "appdb", "db_user": "app", "db_password": "app-secret"},
                 provides=[{"capability": "database", "backend": "mariadb", "default_port": 3306,
                            "field_sources": {
                                "host": {"from": "address"},
                                "port": {"from": "port"},
                                "name": {"from": "value", "key": "db_name"},
                                "user": {"from": "value", "key": "db_user"},
                                "password": {"from": "value", "key": "db_password", "secret": True}}}]),
            _svc("apache2", "native", role="apache2", template="apache2", depends_on=["mariadb"],
                 requires=[{"capability": "database", "backends": ["mysql", "mariadb"],
                            "field_targets": {"host": "db_host", "port": "db_port", "name": "db_name",
                                              "user": "db_user", "password": "db_password"}}],
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
