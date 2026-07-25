"""System clone (test-systems Block 2, config axis) — clone a System's seed host
into a disposable sandbox, so a change can be rehearsed there before prod (see
docs/test-systems.md). DECISION: cross-tier default — a native app is cloned as
a container; the sandbox is cheap + disposable.

Reuses reproduce (export_server_spec spans native config + docker containers) and
materialize_spec (config → agent state store, docker_container → docker deploy).
The clone TRANSFORMS the exported spec for a sandbox:
  - docker container names are prefixed (sbx-<system>-…) so they don't collide
    with the originals, and host port bindings are dropped (a sandbox needs no
    host ports for a config/health rehearsal; avoids port clashes).
Dry-run by default: preview the whole clone (config plan + docker run commands)
before any write. Secrets are NOT cloned here — fresh sandbox secrets from the
password DB are Block 3.
"""
from __future__ import annotations

import re
import secrets as _secrets
from typing import Any

from bossman.db.models import Agent, System
from bossman.services.server_reproduce import export_server_spec, materialize_spec
from bossman.services.vault import Vault

# Field names that hold a secret — a sandbox gets FRESH ones, prod creds are
# never reused (the reproduce decision: secrets live in a secured store by
# reference, never copied into a clone).
_SECRET_KEY_RE = re.compile(r"(pass(wd|word)?|secret|token|api[_-]?key|apikey|credential|priv(ate)?[_-]?key)", re.I)


def _is_secret_key(key: str) -> bool:
    return bool(_SECRET_KEY_RE.search(str(key or "")))


def _fresh_secret() -> str:
    return _secrets.token_urlsafe(18)


def _inject_sandbox_secrets(spec: dict[str, Any], settings) -> tuple[dict[str, Any], list[dict[str, Any]], set[str]]:
    """Replace secret-ish values in the sandbox spec with freshly generated ones
    (so prod secrets are never reused). Returns the spec (with fresh plaintext,
    needed to actually boot the sandbox), the secret_refs (key + a vault handle
    of the fresh value — NOT the value), and the set of fresh plaintexts (so the
    caller can redact them from any preview/output)."""
    try:
        vault: Vault | None = Vault(getattr(settings, "vault_key", ""), getattr(settings, "vault_key_path", "/etc/bossman/vault.key"))
    except Exception:  # noqa: BLE001 — vault optional; still generate fresh secrets
        vault = None
    refs: list[dict[str, Any]] = []
    fresh_values: set[str] = set()

    def _handle(value: str) -> str:
        if vault is None:
            return "(vault unavailable)"
        try:
            return vault.encrypt(value)
        except Exception:  # noqa: BLE001 — VaultError, missing key dir, etc.: still generate fresh secrets
            return "(vault unavailable)"

    # Only docker ENV keys — there the key name IS the secret's name by
    # convention (POSTGRES_PASSWORD, API_KEY, …). We deliberately do NOT scan
    # arbitrary CONFIG values: a config directive named "passwd" (/etc/nsswitch.conf)
    # or "kpasswd" (/etc/services) is NOT a secret, and replacing it with a random
    # value would corrupt the file. Config-value secrets need schema `secret:true`
    # awareness (a follow-up), not a key-name heuristic.
    for r in spec.get("resources") or []:
        if r.get("type") == "docker_container" and isinstance(r.get("env"), dict):
            for k in list(r["env"].keys()):
                if _is_secret_key(k):
                    val = _fresh_secret()
                    r["env"][k] = val
                    fresh_values.add(val)
                    refs.append({"scope": f"docker/{r.get('name')}", "key": k, "handle": _handle(val)})
    return spec, refs, fresh_values


def _redact(obj: Any, secrets_set: set[str]) -> Any:
    """Recursively replace any fresh-secret plaintext in a result with a mask, so
    the API response / preview never leaks the generated sandbox secrets."""
    if not secrets_set:
        return obj
    if isinstance(obj, str):
        out = obj
        for sv in secrets_set:
            if sv:
                out = out.replace(sv, "***")
        return out
    if isinstance(obj, list):
        return [_redact(x, secrets_set) for x in obj]
    if isinstance(obj, dict):
        return {k: _redact(v, secrets_set) for k, v in obj.items()}
    return obj


def _sandbox_prefix(system_name: str) -> str:
    slug = re.sub(r"[^a-zA-Z0-9_.-]+", "-", system_name).strip("-").lower() or "system"
    return f"sbx-{slug}"


def _transform_for_sandbox(spec: dict[str, Any], prefix: str) -> dict[str, Any]:
    """Rewrite an exported spec so it materializes into an isolated sandbox:
    prefix docker container names, drop host port bindings."""
    resources = []
    for r in spec.get("resources") or []:
        if r.get("type") == "docker_container":
            r = {**r, "name": f"{prefix}-{r.get('name')}", "ports": []}
        resources.append(r)
    return {**spec, "resources": resources, "sandbox_prefix": prefix}


async def clone_system(session, system: System, target_agent: Agent, client_factory, settings,
                       dry_run: bool = True) -> dict[str, Any]:
    """Clone `system`'s seed host into a sandbox on `target_agent`. Dry-run by
    default (preview only)."""
    seed = await session.get(Agent, system.seed_agent_id) if system.seed_agent_id else None
    if seed is None:
        return {"error": "system has no seed host to clone from", "system": system.name}

    spec = await export_server_spec(session, seed, client_factory, settings)
    prefix = _sandbox_prefix(system.name)
    sandbox_spec = _transform_for_sandbox(spec, prefix)
    # Block 3: fresh sandbox secrets (prod creds never reused; refs are handles).
    sandbox_spec, secret_refs, fresh_values = _inject_sandbox_secrets(sandbox_spec, settings)
    result = await materialize_spec(session, target_agent, client_factory, settings, sandbox_spec, dry_run=dry_run)
    result = _redact(result, fresh_values)   # never leak the generated secrets
    return {
        "system": {"id": str(system.id), "name": system.name},
        "seed": {"id": str(seed.id), "name": seed.name},
        "target": {"id": str(target_agent.id), "name": target_agent.name},
        "sandbox_prefix": prefix,
        "dry_run": dry_run,
        "source_resource_count": spec.get("resource_count"),
        "secret_refs": secret_refs,
        "secret_count": len(secret_refs),
        "materialize": result,
    }
