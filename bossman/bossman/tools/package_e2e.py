"""Install and configure every package in a fresh Kubernetes pod, and let the package judge the result.

    .venv-host/bin/python -m bossman.tools.package_e2e [--family debian|redhat] [--routes wizard,rule-codec]
                                                       [--only a,b] [--limit N] [--parallel 4] [--check-only]

The host-side half of deploy/test-images/e2e-one.py. For each (family, package) of configs/package_e2e_worklist.json
it starts ONE pod from the family's image (deploy/test-images/build.sh records the tags), passes a spec, waits, reads
the single `E2E_RESULT` line from the pod log and deletes the pod. Nothing is reused between packages.

WHAT A SPEC SAYS, per route:
  wizard / rule-template  the template (from /configs, mounted read-only), its own defaults, and ONE variant: a
                          different enum value, a flipped bool or a number nudged inside its bounds — derived from
                          schema.json, never invented. Free-text strings are not varied: a wrong path or hostname
                          would fail the checker for a reason that says nothing about the template.
  rule-codec              the codec (format/separator/comment) and one change taken from the directive catalog
                          (an enum value other than the default), then read back through the same codec.
  no-config               install only, and confirm nothing under /etc is configuration.
check_cmd / daemon_cmd come from configs/package_validators.json, else the catalog's validate_cmd.

RESUMABLE: results are appended to configs/package_e2e_results.jsonl, one line per run; the latest line per
(family, package) is the result. `infra-error` and a pod timeout are retried on the next run; every other outcome is
a fact about the package and is kept unless --redo names it.

PODS RUN IN PARALLEL (default 4) — they do not touch the LLM endpoint, so this does not conflict with the one-model-
process rule; the minikube node (8 CPU / 32 GB) is the limit.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import threading
import time
import uuid
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

from bossman.tools._paths import configs_dir
from bossman.services.nt_engine import _nest_dotted
from bossman.services.schema_defaults import schema_defaults
from bossman.tools.package_e2e_worklist import NOISE, SCRIPT

CONFIGS = configs_dir(__file__)
WORKLIST = CONFIGS / "package_e2e_worklist.json"
RESULTS = CONFIGS / "package_e2e_results.jsonl"
VALIDATORS = CONFIGS / "package_validators.json"
STATE_DIR = Path(os.environ.get("AGENTIC_BATCH_LOG_DIR", str(Path.home() / ".local/state/agentic-batches")))
IMAGES = STATE_DIR / "pkg-e2e-images.json"
CONTEXT = os.environ.get("PKG_E2E_CONTEXT", "bossman-dev")
NAMESPACE = os.environ.get("PKG_E2E_NAMESPACE", "pkg-e2e")
PROXY = os.environ.get("YOLOMAN_HTTP_PROXY", "http://proxy.example.internal:80")
ROUTE_ORDER = ("wizard", "rule-template", "rule-codec", "no-config", "unrouted")
RETRY = {"infra-error", "pod-timeout", "pod-failed"}
_lock = threading.Lock()


def _load(path: Path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def kubectl(*argv: str, timeout: int = 120, stdin: str | None = None) -> subprocess.CompletedProcess:
    env = {**os.environ, "NO_PROXY": "192.168.49.0/24,localhost,127.0.0.1",
           "no_proxy": "192.168.49.0/24,localhost,127.0.0.1"}
    return subprocess.run(["kubectl", "--context", CONTEXT, "-n", NAMESPACE, *argv], input=stdin,
                          capture_output=True, text=True, timeout=timeout, env=env)


def latest_results() -> dict[tuple[str, str], dict]:
    out: dict[tuple[str, str], dict] = {}
    if RESULTS.is_file():
        for line in RESULTS.read_text().splitlines():
            try:
                r = json.loads(line)
            except ValueError:
                continue
            out[(r.get("family"), r.get("package"))] = r
    return out


# ── spec ──────────────────────────────────────────────────────────────────────────────────────────────────────────

def _defaults(schema: dict) -> dict:
    return schema_defaults(schema)


def template_variant(schema: dict) -> dict:
    """ONE field changed, taken from the schema itself: an enum's other value, a flipped bool, a number nudged
    inside its bounds. First match in field order, so the variant is the same on every run."""
    for name, spec in schema.items():
        if not isinstance(spec, dict) or name.startswith("_"):
            continue
        default, kind = spec.get("default"), spec.get("type")
        enum = spec.get("enum")
        if isinstance(enum, list) and len(enum) >= 2:
            other = next((v for v in enum if v != default), None)
            if other is not None:
                return {name: other}
        if kind in ("bool", "boolean") and isinstance(default, bool):
            return {name: not default}
        if kind in ("number", "integer", "int") and default not in (None, ""):
            try:
                value = int(str(default))
            except ValueError:
                continue
            hi = spec.get("max", spec.get("maximum"))
            nudged = value + 1 if hi is None or value + 1 <= int(hi) else value - 1
            if nudged >= int(spec.get("min", spec.get("minimum", 0)) or 0):
                return {name: nudged}
    return {}


def codec_change(path: str, directives: dict) -> dict:
    """One directive of the file set to a documented value other than its default."""
    for key, spec in sorted((directives.get(path) or {}).items()):
        values = spec.get("values") if isinstance(spec, dict) else None
        if isinstance(values, list) and len(values) >= 2:
            other = next((v for v in values if str(v) != str(spec.get("default"))), None)
            if other is not None:
                return {key: other}
    return {}


def verified(validator: dict) -> bool:
    """A checker entry that ran against the package's shipped file on a test host (by hand or probe_checkers)."""
    return str(validator.get("source") or "").startswith("verified")


def build_spec(family: str, pkg: str, row: dict, validators: dict, catalog: dict, directives: dict) -> dict:
    spec = {"family": family, "package": pkg, "route": row["route"], "target_path": row.get("path", ""),
            "not_config": [SCRIPT.pattern, NOISE.pattern]}
    if row["route"] in ("wizard", "rule-template") and row.get("template"):
        # The template the PRODUCT renders on this family: its own family template for the file wins
        # (nt_engine `@<family>:<path>`). The worklist names the role's template, and the pod rendered Debian's
        # squid.conf on AlmaLinux — Squid 5.5 refused Debian's `to_linklocal` ACL (measured, D1 2026-10-11).
        from bossman.services.wizard_seed import family_templates
        row = {**row, "template": family_templates(CONFIGS / "config_templates").get(
            (family, row.get("path", ""))) or row["template"]}
        schema = _load(CONFIGS / "config_templates" / row["template"] / "schema.json", {})
        # Nested like the product does it (nt_engine._nest_dotted): a schema names `server.host_name`, the template
        # reads `server.host_name` as an attribute — passed flat, 11 templates "failed" in the pod for the harness's
        # sake, not the template's.
        spec.update(template=row["template"], defaults=_nest_dotted(_defaults(schema)),
                    variant=_nest_dotted(template_variant(schema)))
    elif row["route"] == "rule-codec":
        codec = row.get("codec") or {}
        spec.update(codec={"format": codec.get("codec"), "separator": codec.get("separator"),
                           "comment": codec.get("comment")},
                    codec_change=codec_change(row.get("path", ""), directives))
    if row.get("role"):
        branch = ((catalog.get(row["role"]) or {}).get("families") or {}).get(family) or {}
        spec["packages"] = branch.get("packages") or [pkg]
    v = (validators.get(family) or {}).get(pkg) or {}
    if v and not verified(v):
        # A checker the LLM miner proposed from the man page is a hypothesis until it accepted the package's own
        # file on a test host (plan E3; probe_checkers). Used as is, 850 mined entries turned 52 packages
        # validate-/daemon-failed in one run — atmsigd without an ATM socket, bird's checker run on envvars.
        spec["checker_unverified"] = v.get("check_cmd") or v.get("daemon_cmd")
        v = {}
    check = v.get("check_cmd")
    # A checker belongs to a FILE: dockerd --validate checks daemon.json, not /etc/default/docker, which is what the
    # docker.io row configures. And one that needs a capability the unprivileged pod lacks (nft -c with
    # `flush ruleset` needs CAP_NET_ADMIN) is not run here — said, instead of a validate-failed the file never earned.
    if check and v.get("for_path") and v["for_path"] != row.get("path"):
        spec["check_skipped"] = f"the checker is for {v['for_path']}, this row configures {row.get('path')}"
        check = None
    elif check and v.get("needs"):
        spec["check_skipped"] = f"the checker needs {v['needs']}, which the unprivileged test pod does not have"
        check = None
    if not check and row.get("role"):
        check = (catalog.get(row["role"]) or {}).get("validate_cmd")
    spec.update(check_cmd=check, daemon_cmd=v.get("daemon_cmd"))
    return spec


# ── pod ───────────────────────────────────────────────────────────────────────────────────────────────────────────

def pod_manifest(name: str, image: str, spec: dict) -> dict:
    return {
        "apiVersion": "v1", "kind": "Pod",
        "metadata": {"name": name, "namespace": NAMESPACE, "labels": {"app": "pkg-e2e"}},
        "spec": {
            "restartPolicy": "Never",
            "activeDeadlineSeconds": 1500,
            "containers": [{
                "name": "e2e", "image": image, "imagePullPolicy": "Never",
                "env": [{"name": "E2E_SPEC", "value": json.dumps(spec)},
                        {"name": "http_proxy", "value": PROXY}, {"name": "https_proxy", "value": PROXY},
                        {"name": "no_proxy", "value": ".example.internal,localhost"}],
                "resources": {"requests": {"cpu": "250m", "memory": "256Mi"}, "limits": {"memory": "3Gi"}},
                "volumeMounts": [{"name": "configs", "mountPath": "/configs", "readOnly": True}],
            }],
            "volumes": [{"name": "configs", "hostPath": {"path": "/configs", "type": "Directory"}}],
        },
    }


def run_one(family: str, pkg: str, image: str, spec: dict, timeout: int = 1500) -> dict:
    name = f"e2e-{family[:3]}-{uuid.uuid4().hex[:10]}"
    t0 = time.monotonic()
    created = kubectl("apply", "-f", "-", stdin=json.dumps(pod_manifest(name, image, spec)))
    if created.returncode != 0:
        return {"outcome": "infra-error", "reason": f"pod create: {created.stderr.strip()[:300]}"}
    try:
        phase = ""
        while time.monotonic() - t0 < timeout:
            got = kubectl("get", "pod", name, "-o", "jsonpath={.status.phase}", timeout=60)
            phase = got.stdout.strip()
            if phase in ("Succeeded", "Failed"):
                break
            time.sleep(3)
        logs = kubectl("logs", name, timeout=120).stdout
        line = next((ln for ln in reversed(logs.splitlines()) if ln.startswith("E2E_RESULT ")), None)
        if line:
            res = json.loads(line[len("E2E_RESULT "):])
        elif phase not in ("Succeeded", "Failed"):
            res = {"outcome": "pod-timeout", "reason": f"no result after {timeout}s (phase {phase or '?'})"}
        else:
            res = {"outcome": "pod-failed", "reason": f"phase {phase}, no result line; log tail: {logs[-500:]}"}
    finally:
        kubectl("delete", "pod", name, "--wait=false", "--grace-period=1", timeout=60)
    res["pod_seconds"] = round(time.monotonic() - t0, 1)
    return res


def record(row: dict) -> None:
    with _lock, open(RESULTS, "a") as fh:
        fh.write(json.dumps(row) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--family", choices=("debian", "redhat"), action="append")
    ap.add_argument("--routes", default="wizard,rule-template,rule-codec,no-config")
    ap.add_argument("--only", default="")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--parallel", type=int, default=4, help="pods at once (no LLM involved). Default 4.")
    ap.add_argument("--redo", default="", help="comma-separated outcomes to run again (e.g. validate-failed)")
    ap.add_argument("--check-only", action="store_true", help="print the outcome table, start nothing")
    args = ap.parse_args()

    worklist = _load(WORKLIST, {}).get("families", {})
    images = _load(IMAGES, {})
    validators = _load(VALIDATORS, {})
    catalog = _load(CONFIGS / "package_catalog.json", {})
    directives = _load(CONFIGS / "config_directives.json", {})
    families = args.family or ["debian", "redhat"]
    routes = [r for r in ROUTE_ORDER if r in args.routes.split(",")]
    only = {s.strip() for s in args.only.split(",") if s.strip()}
    redo = {s.strip() for s in args.redo.split(",") if s.strip()} | RETRY
    done = latest_results()

    if args.check_only:
        table: dict[str, Counter] = {}
        for fam in families:
            for pkg, row in worklist.get(fam, {}).items():
                r = done.get((fam, pkg))
                table.setdefault(f"{fam}/{row['route']}", Counter())[r["outcome"] if r else "pending"] += 1
        for key in sorted(table):
            print(f"{key:28s} " + ", ".join(f"{k} {v}" for k, v in table[key].most_common()))
        return 0

    # A package whose route is NOW unrouted keeps its last pod result otherwise — a stale `target-missing` for a file
    # the worklist no longer assigns (apt-config-icons: once routed to the appstream template, now unrouted with
    # its own /etc/apt/apt.conf.d/60icons). Nothing vanishes silently: one row naming the current route and reason.
    rerouted = 0
    for fam in families:
        for pkg, row in worklist.get(fam, {}).items():
            prev = done.get((fam, pkg))
            # `replaced` likewise: the repository installs another package (rpm_replacements), so hirte's
            # render-failed for /etc/hirte/hirte.conf is about a file no host gets — not a result to keep showing.
            route = row.get("route")
            # ...and a package that NEVER had a route gets its row too: 283 unrouted packages stood as "pending" in
            # the table although nothing will ever run for them — pending means "not yet", unrouted means "no route
            # reaches its file, and here is why" (found 2026-10-16). No pod: there is nothing to configure.
            if route in ("unrouted", "replaced") and (prev is None or prev.get("outcome") != route):
                why = (f"no route reaches {row.get('path') or 'its file'}: {row.get('reason', '')}".rstrip(": ")
                       if route == "unrouted" else row.get("reason", ""))
                new = {"family": fam, "package": pkg, "route": route, "outcome": route, "reason": why,
                       "previous": (prev or {}).get("outcome"), "at": time.strftime("%Y-%m-%dT%H:%M:%S")}
                record(new)
                done[(fam, pkg)] = new
                rerouted += 1
    if rerouted:
        print(f"{rerouted} result row(s) now say `unrouted`/`replaced` — no route to test (new, or changed since "
              f"the last run)", flush=True)

    todo = []
    for route in routes:
        for fam in families:
            for pkg, row in sorted(worklist.get(fam, {}).items()):
                if row["route"] != route or (only and pkg not in only):
                    continue
                prev = done.get((fam, pkg))
                # A result counts only for the route it was measured on: 29 packages had a result of an OLD route
                # (11 Debian ones `unrouted`, since then routed to a template) and their current route was never
                # run (found 2026-10-15). A row without a route is from before routes were recorded: kept.
                if prev and prev.get("route", route) == route and prev.get("outcome") not in redo:
                    continue
                todo.append((fam, pkg, row))
    if args.limit:
        todo = todo[: args.limit]
    print(f"package_e2e: {len(todo)} package(s), {args.parallel} pod(s) at a time, images {images}", flush=True)

    def work(item):
        fam, pkg, row = item
        spec = build_spec(fam, pkg, row, validators, catalog, directives)
        res = run_one(fam, pkg, images[fam], spec)
        out = {"family": fam, "package": pkg, "route": row["route"], "image": images[fam],
               "at": time.strftime("%Y-%m-%dT%H:%M:%S"), "spec": {k: spec.get(k) for k in
                                                                  ("template", "variant", "codec_change",
                                                                   "check_cmd", "daemon_cmd")}, **res}
        out["family"], out["package"] = fam, pkg
        if spec.get("check_skipped") and out.get("outcome") == "pass-unverified":
            out["reason"] = spec["check_skipped"]
        record(out)
        return out

    counts: Counter = Counter()
    with ThreadPoolExecutor(max_workers=max(1, args.parallel)) as pool:
        futures = [pool.submit(work, item) for item in todo]
        for i, fut in enumerate(as_completed(futures), 1):
            r = fut.result()
            counts[r["outcome"]] += 1
            print(f"[{i}/{len(todo)}] {r['family']}/{r['package']} ({r['route']}): {r['outcome']} "
                  f"({r.get('pod_seconds')}s)", flush=True)
    print("outcomes:", dict(counts), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
