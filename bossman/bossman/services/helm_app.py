"""Helm / Kubernetes app target (app-system increment 3) — the orchestrated tier
of the unified App model (native | docker | k8s, docs/app-model.md). Two halves,
both driven via the host's `helm` CLI through the agent command tool:

- AVAILABLE (the App-Store catalog): `helm search repo` = charts you CAN deploy;
  `helm show values` = the chart's default values → the configure form (values
  are rendered FROM the chart, exactly like the native templates' schema.json).
  These need NO cluster (chart-local ops).
- DEPLOYED (what's running): `helm list -A` = installed releases (status,
  revision) for the App-Store "what k8s deployments exist" view + rollback.
  `helm template` previews; install/upgrade/rollback/uninstall mutate the
  cluster. These need a kubeconfig/cluster on the host.

Read ops (repos/search/show/list/template) are safe; install/rollback/uninstall
mutate.
"""
from __future__ import annotations

import json
import shlex
from typing import Any

import yaml


# --- values.yaml → flat schema/values (so the UI renders a typed FORM, not a
# raw values.yaml textarea — the gap every Helm UI leaves open) --------------

def _scalar_type(v: Any) -> str | None:
    if isinstance(v, bool):
        return "bool"
    if isinstance(v, (int, float)):
        return "number"
    if isinstance(v, str):
        return "string"
    return None


def derive_schema(values: Any, prefix: str = "") -> tuple[dict[str, Any], dict[str, Any]]:
    """Walk a parsed values.yaml into a FLAT dotted-key schema + values, the same
    shape param-form renders for config templates. Scalars and scalar-lists become
    editable fields; nested dicts recurse (dotted keys); lists-of-objects and other
    complex structures are skipped (they stay editable via the YAML view). Every
    field carries its current value as `default`, so the form prefills the chart's
    own defaults."""
    schema: dict[str, Any] = {}
    flat: dict[str, Any] = {}
    if not isinstance(values, dict):
        return schema, flat
    for key, v in values.items():
        dotted = f"{prefix}{key}"
        st = _scalar_type(v)
        if st is not None:
            schema[dotted] = {"type": st, "default": v}
            flat[dotted] = v
        elif isinstance(v, list):
            # Only scalar lists get a field; list-of-objects is too complex for a flat form.
            if all(_scalar_type(e) is not None for e in v):
                schema[dotted] = {"type": "list", "default": v}
                flat[dotted] = v
        elif isinstance(v, dict):
            sub_s, sub_f = derive_schema(v, prefix=f"{dotted}.")
            schema.update(sub_s)
            flat.update(sub_f)
        # None / other → skip (no sensible form control; YAML view still covers it).
    return schema, flat


def flat_to_yaml(flat: dict[str, Any]) -> str:
    """Inverse of derive_schema: dotted-key form values → nested dict → YAML, so a
    form edit round-trips back into a values.yaml helm can consume."""
    root: dict[str, Any] = {}
    for dotted, value in flat.items():
        parts = dotted.split(".")
        node = root
        for p in parts[:-1]:
            nxt = node.get(p)
            if not isinstance(nxt, dict):
                nxt = {}
                node[p] = nxt
            node = nxt
        node[parts[-1]] = value
    return yaml.safe_dump(root, default_flow_style=False, sort_keys=False) if root else ""


# Bossman-wide helm HTTP proxy, editable in Admin Settings (DB-backed
# SystemSettings, NOT an env var — the user's explicit call: "die Proxy
# Einstellungen müssen in den Admin Settings gesetzt werden"). Cached here as a
# module global so _proxied() stays sync and every helm path (REST, resource,
# MCP) picks it up without threading a session through all 8 helm_app functions.
# Seeded once at startup (main.lifespan) and refreshed on every PUT
# (api/system_settings.set_helm_proxy) so it flips instantly in-process.
_DEFAULT_NO_PROXY = ".example.internal,localhost,127.0.0.1,10.0.0.0/8,192.168.0.0/16,.svc,.cluster.local"
_HELM_PROXY: tuple[str, str] = ("", _DEFAULT_NO_PROXY)  # (http_proxy, no_proxy)


def set_helm_proxy(http_proxy: str | None, no_proxy: str | None) -> None:
    """Update the cached helm proxy (called at startup and on every Admin-Settings
    write). Empty http_proxy disables proxying; empty no_proxy falls back to the
    sensible default that keeps cluster/local/corp traffic direct."""
    global _HELM_PROXY
    _HELM_PROXY = ((http_proxy or "").strip(), (no_proxy or "").strip() or _DEFAULT_NO_PROXY)


def _proxied(settings, argv: list[str]) -> list[str]:
    """Wrap a helm command so it uses the agent-side HTTP proxy when one is
    configured in Admin Settings. helm runs ON THE AGENT HOST; if a chart lives in
    an internet OCI registry (bitnami → oci://registry-1.docker.io) a host with no
    direct egress times out. `export` is used so the vars apply to every statement
    of the multi-command render/install scripts; NO_PROXY keeps cluster/local
    traffic (kubectl, minikube) direct. No proxy set → argv unchanged. `settings`
    is accepted for call-site symmetry but the value comes from the cache above."""
    proxy, noproxy = _HELM_PROXY
    if not proxy:
        return argv
    envp = (f"export HTTPS_PROXY={shlex.quote(proxy)} HTTP_PROXY={shlex.quote(proxy)} "
            f"NO_PROXY={shlex.quote(noproxy)} https_proxy={shlex.quote(proxy)} "
            f"http_proxy={shlex.quote(proxy)} no_proxy={shlex.quote(noproxy)}; ")
    if argv[:2] == ["sh", "-c"]:
        return ["sh", "-c", envp + argv[2]]
    return ["sh", "-c", envp + " ".join(shlex.quote(a) for a in argv)]


async def _run(client, argv: list[str], settings=None) -> dict[str, Any]:
    r = await client.call_tool("command", {"argv": _proxied(settings, argv)})
    return (r or {}).get("data") if isinstance(r, dict) else {}


def _json_lines_or_array(stdout: str) -> list[dict[str, Any]]:
    stdout = (stdout or "").strip()
    if not stdout:
        return []
    try:
        v = json.loads(stdout)
        return v if isinstance(v, list) else [v]
    except ValueError:
        out = []
        for line in stdout.splitlines():
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
        return out


async def list_releases(agent, client_factory, settings) -> dict[str, Any]:
    """Installed Helm releases on the cluster (helm list -A) — the deployed k8s
    apps. Needs a cluster; returns an error note if none is reachable."""
    data = await _run(client_factory(agent, settings), ["helm", "list", "-A", "-o", "json"], settings)
    rc = data.get("rc")
    releases = _json_lines_or_array(data.get("stdout", "")) if rc == 0 else []
    out = {
        "agent": {"id": str(agent.id), "name": agent.name},
        "releases": [
            {"name": r.get("name"), "namespace": r.get("namespace"), "chart": r.get("chart"),
             "app_version": r.get("app_version"), "status": r.get("status"), "revision": r.get("revision")}
            for r in releases
        ],
        "count": len(releases),
    }
    if rc != 0:
        out["error"] = (data.get("stderr") or "helm list failed (no cluster?)").strip()[:200]
    return out


async def list_repos(agent, client_factory, settings) -> dict[str, Any]:
    data = await _run(client_factory(agent, settings), ["helm", "repo", "list", "-o", "json"], settings)
    repos = _json_lines_or_array(data.get("stdout", "")) if data.get("rc") == 0 else []
    return {"repos": [{"name": r.get("name"), "url": r.get("url")} for r in repos], "count": len(repos)}


async def add_repo(agent, client_factory, settings, *, name: str, url: str) -> dict[str, Any]:
    client = client_factory(agent, settings)
    add = await _run(client, ["helm", "repo", "add", name, url], settings)
    await _run(client, ["helm", "repo", "update", name], settings)
    return {"name": name, "url": url, "ok": add.get("rc") == 0, "stderr": (add.get("stderr") or "").strip()[:200]}


async def search_charts(agent, client_factory, settings, *, query: str = "") -> dict[str, Any]:
    """Available charts to deploy (helm search repo) — the App-Store k8s catalog."""
    argv = ["helm", "search", "repo", "-o", "json"] + ([query] if query else [])
    data = await _run(client_factory(agent, settings), argv, settings)
    charts = _json_lines_or_array(data.get("stdout", "")) if data.get("rc") == 0 else []
    return {
        "charts": [
            {"name": c.get("name"), "version": c.get("version"),
             "app_version": c.get("app_version"), "description": c.get("description")}
            for c in charts
        ],
        "count": len(charts),
    }


async def chart_values(agent, client_factory, settings, *, chart: str) -> dict[str, Any]:
    """The chart's default values.yaml — what the configure form is rendered from
    (the k8s analog of a template's schema.json/sample)."""
    client = client_factory(agent, settings)
    vals = await _run(client, ["helm", "show", "values", chart], settings)
    meta = await _run(client, ["helm", "show", "chart", chart], settings)
    values_yaml = (vals.get("stdout") or "") if vals.get("rc") == 0 else ""
    schema: dict[str, Any] = {}
    flat: dict[str, Any] = {}
    try:
        parsed = yaml.safe_load(values_yaml) if values_yaml.strip() else None
        schema, flat = derive_schema(parsed)
    except yaml.YAMLError:
        pass  # unparseable values.yaml → form unavailable, YAML view still works
    return {
        "chart": chart,
        "values_yaml": values_yaml,
        "chart_yaml": (meta.get("stdout") or "") if meta.get("rc") == 0 else "",
        "values_schema": schema,   # flat dotted-key schema → param-form (the typed FORM)
        "flat_values": flat,       # the chart's defaults, prefilled into the form
        "error": None if vals.get("rc") == 0 else (vals.get("stderr") or "").strip()[:200],
    }


async def render_release(agent, client_factory, settings, *, name: str, chart: str,
                         values_yaml: str = "", values: dict[str, Any] | None = None,
                         namespace: str = "default") -> dict[str, Any]:
    """helm template — render the manifests WITHOUT a cluster (preview/plan).
    A flat dotted-key `values` map (from the form) is converted to YAML."""
    if values and not values_yaml.strip():
        values_yaml = flat_to_yaml(values)
    client = client_factory(agent, settings)
    argv = ["helm", "template", name, chart, "-n", namespace]
    if values_yaml.strip():
        # write the values to a temp file the CLI can -f
        import shlex
        b64 = None
        try:
            import base64
            b64 = base64.b64encode(values_yaml.encode()).decode()
        except Exception:  # noqa: BLE001
            b64 = None
        if b64:
            wrapped = (f"f=$(mktemp); echo {shlex.quote(b64)} | base64 -d > $f; "
                       f"helm template {shlex.quote(name)} {shlex.quote(chart)} -n {shlex.quote(namespace)} -f $f; rm -f $f")
            data = await _run(client, ["sh", "-c", wrapped], settings)
            return {"rendered": (data.get("stdout") or "")[:20000], "ok": data.get("rc") == 0,
                    "error": (data.get("stderr") or "").strip()[:300] if data.get("rc") != 0 else None}
    data = await _run(client, argv, settings)
    return {"rendered": (data.get("stdout") or "")[:20000], "ok": data.get("rc") == 0,
            "error": (data.get("stderr") or "").strip()[:300] if data.get("rc") != 0 else None}


async def install_release(agent, client_factory, settings, *, name: str, chart: str,
                          values_yaml: str = "", values: dict[str, Any] | None = None,
                          namespace: str = "default",
                          create_namespace: bool = True, wait: bool = False) -> dict[str, Any]:
    """helm upgrade --install — deploy/upgrade a release on the cluster (mutating,
    needs a kubeconfig). Idempotent by design (upgrade-or-install). A flat
    dotted-key `values` map (from the form) is converted to YAML."""
    import base64
    import shlex
    if values and not values_yaml.strip():
        values_yaml = flat_to_yaml(values)
    ns = shlex.quote(namespace)
    base = f"helm upgrade --install {shlex.quote(name)} {shlex.quote(chart)} -n {ns}"
    if create_namespace:
        base += " --create-namespace"
    if wait:
        base += " --wait"
    if values_yaml.strip():
        b64 = base64.b64encode(values_yaml.encode()).decode()
        script = f"f=$(mktemp); echo {shlex.quote(b64)} | base64 -d > $f; {base} -f $f -o json; rm -f $f"
    else:
        script = f"{base} -o json"
    data = await _run(client_factory(agent, settings), ["sh", "-c", script], settings)
    return {"name": name, "chart": chart, "namespace": namespace, "ok": data.get("rc") == 0,
            "stdout": (data.get("stdout") or "")[:2000], "error": (data.get("stderr") or "").strip()[:400] if data.get("rc") != 0 else None}


async def rollback_release(agent, client_factory, settings, *, name: str,
                           revision: int | None = None, namespace: str = "default") -> dict[str, Any]:
    """helm rollback — revert a release to a previous revision (0/None = last)."""
    argv = ["helm", "rollback", name] + ([str(revision)] if revision is not None else []) + ["-n", namespace]
    data = await _run(client_factory(agent, settings), argv, settings)
    return {"name": name, "namespace": namespace, "revision": revision, "ok": data.get("rc") == 0,
            "stdout": (data.get("stdout") or "").strip()[:400], "error": (data.get("stderr") or "").strip()[:400] if data.get("rc") != 0 else None}


async def uninstall_release(agent, client_factory, settings, *, name: str, namespace: str = "default") -> dict[str, Any]:
    """helm uninstall — remove a release from the cluster."""
    data = await _run(client_factory(agent, settings), ["helm", "uninstall", name, "-n", namespace], settings)
    return {"name": name, "namespace": namespace, "ok": data.get("rc") == 0,
            "stdout": (data.get("stdout") or "").strip()[:400], "error": (data.get("stderr") or "").strip()[:400] if data.get("rc") != 0 else None}
