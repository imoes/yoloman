"""The Starlark module library (docs/plan.md Blocks G7/G8): storage,
validation, and the authoring contract for collection modules translated
to Starlark. The Go agent keeps `ansible.builtin` as native modules; the
collections (ansible.posix, community.general/docker/crypto) are written
in Starlark — "like Ansible, but the collections run sandboxed inside the
agent" (user decision).

Three cooperating pieces:
- CONTRACT_MARKDOWN — the complete authoring contract. Embedded verbatim
  in the MCP tools' descriptions (the "skill, not a one-liner" convention
  from docs/plan.md) so an LLM can produce clean modules without external
  documentation.
- validate_star() — shells out to the Go `starlark-check` binary
  (cmd/starlark-check, internal/starmod) and returns its structured JSON
  report. Bossman never re-implements the contract check in Python; the
  single validator is the one the agent's future runtime (Block G3) is
  built from, so "validates here" and "runs there" can never drift.
- submit()/status() — the library on disk: one
  `<modules_dir>/<collection>/<name>.star` + `.yaml` pair per module,
  written only after the hard validation gate passes. Progress/resume
  state is derived from the filesystem, never tracked separately.
"""

from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

# Collections in translation scope (the 71 ansible.builtin modules stay
# native Go — see docs/plan.md Block G8).
COLLECTIONS = ["ansible.posix", "community.crypto", "community.docker", "community.general"]

CONTRACT_MARKDOWN = """\
# Starlark module contract v1

You are writing one module for the yolo-man agent's Starlark runtime — a
sandboxed Python dialect (Starlark) executed inside a Go agent. The module
replaces one Ansible module; behave like that Ansible module (same
parameters, same semantics, idempotent) unless told otherwise.

## File shape

One `.star` file. It MUST define exactly:

    def main(ctx, params):

- `params` is a dict of the module's arguments (already validated against
  the metadata argspec; missing optional keys are simply absent — use
  `params.get("key", default)`).
- No `load()` statements — the module is self-contained. Helper `def`s and
  module-level constants are fine. No recursion. `while` loops are
  allowed but every loop must provably terminate.
- Standard Starlark builtins are available (dict/list/str methods, len,
  range, sorted, enumerate, zip, str, int, float, bool, type, fail,
  set()). There is NO Python stdlib: no re, no os, no json module —
  interact with the system exclusively through `ctx`.

## The ctx API (capability builtins — the ONLY way to touch the system)

- `ctx.check_mode` → bool. True = dry-run: predict, never mutate.
- `ctx.run(argv, mutates=False, ok_codes=[0])` →
  `struct(rc, stdout, stderr, skipped)`. Executes argv directly (a list
  of strings, NO shell — no pipes/redirects/globs in argv). Set
  `mutates=True` on ANY command that changes system state; the runtime
  then skips it in check_mode and returns `skipped=True` — always handle
  that branch by returning the predicted result with the right `changed`.
  Read-only probes keep `mutates=False` and run even in check_mode.
- `ctx.file_read(path)` → str. fail()s if unreadable.
- `ctx.file_write(path, content, mode=None)` → bool `changed`. Writes
  atomically; in check_mode it writes nothing and returns whether it
  WOULD change. mode is an octal string like "0644".
- `ctx.file_exists(path)` → bool.
- `ctx.stat(path)` → dict {exists, size, mode, uid, gid, is_dir,
  is_link} or None if missing.
- `ctx.facts()` → dict with at least: os_family ("debian"/"redhat"/...),
  distribution, hostname, architecture.

## Return contract

Return a dict:

    {"changed": bool, "msg": str}            # required keys
    {"changed": ..., "msg": ..., "data": {}} # optional extra results

- `changed` MUST be False when the system already matched the desired
  state (idempotency), and in check_mode it MUST be the predicted value.
- Errors: call `fail("message")` — never return an error dict, never
  swallow a non-ok exit code silently. Check `res.rc` against your
  expected codes.

## check_mode discipline (this is what reviewers reject first)

1. Probe current state with read-only calls (`mutates=False`).
2. If already in desired state → `{"changed": False, ...}` — in BOTH modes.
3. If a change is needed and `ctx.check_mode` → do NOT mutate; return
   `{"changed": True, "msg": "would ..."}` (the `skipped` branch of a
   mutating `ctx.run` gives you this for free).
4. Otherwise perform the change, verify rc, return `{"changed": True, ...}`.

## Example (complete, contract-correct)

    def main(ctx, params):
        name = params["name"]
        state = params.get("state", "started")
        res = ctx.run(["systemctl", "is-active", name])
        active = res.rc == 0
        if state == "started":
            if active:
                return {"changed": False, "msg": name + " already started"}
            start = ctx.run(["systemctl", "start", name], mutates=True)
            if start.skipped:
                return {"changed": True, "msg": "would start " + name}
            if start.rc != 0:
                fail("failed to start " + name + ": " + start.stderr)
            return {"changed": True, "msg": "started " + name}
        fail("unsupported state: " + state)

## Metadata YAML (submitted alongside the .star file)

    name: docker_container            # short module name
    fqcn: community.docker.docker_container
    collection: community.docker
    short_description: one line
    description: >
      longer prose
    options:                          # the argspec, mirroring the original
      name: {type: str, required: true, description: ...}
      state: {type: str, choices: [present, absent], default: present, description: ...}
    writes: true                      # false only for pure *_info/*_facts modules
    runtime: starlark
    source: translated                # generated | translated | custom
    examples: |
      - community.docker.docker_container:
          name: web
          state: present
"""


@dataclass
class ValidationResult:
    """The starlark-check JSON report, plus transport-level failure info."""

    ok: bool
    stub_ok: bool
    errors: list[dict[str, Any]] = field(default_factory=list)
    warnings: list[dict[str, Any]] = field(default_factory=list)
    calls: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "stub_ok": self.stub_ok,
            "errors": self.errors,
            "warnings": self.warnings,
            "calls": self.calls,
        }


class ModuleLibraryError(Exception):
    """Raised for library-level failures (bad metadata, unknown fqcn,
    validator unavailable) — always carries a human-readable message."""


def validate_star(starlark_check_path: str, star_code: str, params: dict[str, Any] | None = None) -> ValidationResult:
    """Runs the Go validator on one module's source. The subprocess is the
    deliberate design (not a Python reimplementation): the same binary is
    built from the same internal/starmod package the agent's runtime will
    use, so validation semantics cannot drift from execution semantics."""
    argv = [starlark_check_path]
    if params:
        argv += ["-params", json.dumps(params)]
    argv.append("-")
    try:
        proc = subprocess.run(argv, input=star_code.encode(), capture_output=True, timeout=60)
    except FileNotFoundError as exc:
        raise ModuleLibraryError(f"starlark-check binary not found at {starlark_check_path!r}") from exc
    except subprocess.TimeoutExpired as exc:
        raise ModuleLibraryError("starlark-check timed out after 60s") from exc
    if proc.returncode not in (0, 1):  # 0 = ok, 1 = validation failed, else = usage/crash
        raise ModuleLibraryError(f"starlark-check failed (rc={proc.returncode}): {proc.stderr.decode(errors='replace')}")
    try:
        report = json.loads(proc.stdout.decode())
    except json.JSONDecodeError as exc:
        raise ModuleLibraryError(f"starlark-check produced invalid JSON: {exc}") from exc
    return ValidationResult(
        ok=bool(report.get("ok")),
        stub_ok=bool(report.get("stub_ok")),
        errors=report.get("errors") or [],
        warnings=report.get("warnings") or [],
        calls=report.get("calls") or [],
    )


_REQUIRED_METADATA_KEYS = ["name", "fqcn", "collection", "short_description", "options", "writes", "runtime"]


def parse_metadata(metadata_yaml: str) -> dict[str, Any]:
    """Parses and structurally validates a module's metadata YAML against
    the G1 schema subset submit_module requires."""
    try:
        meta = yaml.safe_load(metadata_yaml)
    except yaml.YAMLError as exc:
        raise ModuleLibraryError(f"metadata is not valid YAML: {exc}") from exc
    if not isinstance(meta, dict):
        raise ModuleLibraryError("metadata must be a YAML mapping")
    missing = [k for k in _REQUIRED_METADATA_KEYS if k not in meta]
    if missing:
        raise ModuleLibraryError(f"metadata is missing required keys: {', '.join(missing)}")
    if meta["runtime"] != "starlark":
        raise ModuleLibraryError(f"runtime must be 'starlark' for a translated module, got {meta['runtime']!r}")
    if not isinstance(meta["options"], dict):
        raise ModuleLibraryError("options must be a mapping of option name -> spec")
    expected_fqcn = f"{meta['collection']}.{meta['name']}"
    if meta["fqcn"] != expected_fqcn:
        raise ModuleLibraryError(f"fqcn {meta['fqcn']!r} does not match collection.name ({expected_fqcn!r})")
    return meta


def module_paths(modules_dir: str | Path, fqcn: str) -> tuple[Path, Path]:
    """The on-disk .yaml/.star pair for one fqcn."""
    collection, _, name = fqcn.rpartition(".")
    base = Path(modules_dir) / collection
    return base / f"{name}.yaml", base / f"{name}.star"


def submit(
    modules_dir: str | Path,
    starlark_check_path: str,
    fqcn: str,
    metadata_yaml: str,
    star_code: str,
    params: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """The write path of the library: metadata check + hard validation
    gate, then persist the pair. Returns {stored, paths, validation}."""
    meta = parse_metadata(metadata_yaml)
    if meta["fqcn"] != fqcn:
        raise ModuleLibraryError(f"fqcn argument {fqcn!r} does not match metadata fqcn {meta['fqcn']!r}")

    result = validate_star(starlark_check_path, star_code, params)
    if not result.ok:
        return {"stored": False, "validation": result.to_dict()}

    yaml_path, star_path = module_paths(modules_dir, fqcn)
    yaml_path.parent.mkdir(parents=True, exist_ok=True)
    yaml_path.write_text(metadata_yaml, encoding="utf-8")
    star_path.write_text(star_code, encoding="utf-8")
    return {
        "stored": True,
        "paths": {"metadata": str(yaml_path), "star": str(star_path)},
        "validation": result.to_dict(),
    }


def load_source(module_sources_dir: str | Path, fqcn: str) -> dict[str, Any]:
    """One module's translation template from the pre-dumped sources
    (scripts/dump_module_sources.py): argspec/doc/examples + the original
    Python implementation."""
    path = Path(module_sources_dir) / f"{fqcn}.json"
    if not path.exists():
        raise ModuleLibraryError(f"no dumped source for {fqcn!r} — run scripts/dump_module_sources.py")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ModuleLibraryError(f"cannot read dumped source for {fqcn!r}: {exc}") from exc


def status(modules_dir: str | Path, module_sources_dir: str | Path) -> dict[str, Any]:
    """Translation progress, derived purely from the filesystem: the dump
    defines the universe, a stored .star+.yaml pair means translated."""
    sources = sorted(p.stem for p in Path(module_sources_dir).glob("*.json"))
    per_collection: dict[str, dict[str, Any]] = {}
    translated_total = 0
    for fqcn in sources:
        collection, _, _name = fqcn.rpartition(".")
        entry = per_collection.setdefault(collection, {"total": 0, "translated": 0, "missing": []})
        entry["total"] += 1
        yaml_path, star_path = module_paths(modules_dir, fqcn)
        if yaml_path.exists() and star_path.exists():
            entry["translated"] += 1
            translated_total += 1
        else:
            entry["missing"].append(fqcn)
    return {
        "total": len(sources),
        "translated": translated_total,
        "collections": per_collection,
    }
