"""The Starlark module library (docs/plan.md Blocks G7/G8): storage,
validation, and the authoring contract for collection modules translated
to Starlark. The Go agent keeps `ansible.builtin` as native modules; the
collections (posix, community.general/docker/crypto) are written
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
COLLECTIONS = ["posix", "community.crypto", "community.docker", "community.general"]

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

## Starlark is NOT Python — these WILL fail; use the replacement

Starlark looks like Python but is a smaller, safer language. Do NOT use:

- `x is None` / `x is not None`  →  use `x == None` / `x != None`.
  **This is by far the most common mistake — the `is` operator does not
  exist in Starlark and is a hard parse error. Never write `is`/`is not`.**
- `try:` / `except:` / `raise`  →  there are no exceptions. Call
  `fail("message")` to abort. The `ctx.*` builtins already `fail()` on
  error, so never wrap them in try/except — just call them.
- f-strings `f"{x}"`  →  use `"prefix %s" % x`, `"a" + str(x)`, or `"{}".format(x)`.
- `import ...` / `from ...`  →  none; the module is self-contained.
- `class ...`  →  none; use plain functions and dicts.
- `lambda`  →  define a named nested `def`.
- `isinstance(x, T)`  →  Starlark has no isinstance. Use `type(x) == "bool"`
  (also "int", "string", "list", "dict", "NoneType", "float").
- `while True:` / unbounded loops  →  loop over a list or `range(n)`;
  every loop must terminate.
- regular expressions (`re`)  →  use str methods: `split`, `rsplit`,
  `find`, `startswith`, `endswith`, `strip`, `replace`, `splitlines`.
- `open()`, `os.`, `sys.`, `json.`, `print()`  →  none; touch the system
  only through `ctx.*`.
- `d[key]` raises no catchable error and hard-fails if key is missing  →
  use `d.get(key)` or `d.get(key, default)`.

Available builtins: len, range, enumerate, zip, sorted, reversed, min,
max, abs, any, all, bool, int, float, str, list, dict, tuple, type, hash,
getattr, hasattr, fail. String methods: split, rsplit, splitlines, strip,
lstrip, rstrip, startswith, endswith, find, index, count, replace, lower,
upper, title, join, format. Ternary `A if cond else B`, list/dict
comprehensions, and `for`/`if`/`elif`/`else` all work normally.

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

## Example 2 — editing a config file idempotently (the most common pattern)

Note: no `is None` (uses `== None`), no try/except (file_read fail()s on
its own), file_write handles check_mode and returns the predicted change.

    def main(ctx, params):
        path = params.get("path", "/etc/sysctl.conf")
        key = params["name"]
        value = params.get("value")
        state = params.get("state", "present")
        if state == "present" and value == None:
            fail("value is required when state is present")

        content = ctx.file_read(path) if ctx.file_exists(path) else ""
        lines = content.split("\\n")
        line = key + " = " + str(value)

        new_lines = []
        found = False
        for l in lines:
            stripped = l.strip()
            is_entry = stripped.startswith(key + "=") or stripped.startswith(key + " =")
            if is_entry:
                found = True
                if state == "present":
                    new_lines.append(line)
                # state == absent: drop the line by not appending it
            else:
                new_lines.append(l)
        if state == "present" and not found:
            new_lines.append(line)

        new_content = "\\n".join(new_lines)
        if new_content == content:
            return {"changed": False, "msg": key + " already correct"}
        changed = ctx.file_write(path, new_content)
        verb = "would update " if ctx.check_mode else "updated "
        return {"changed": changed, "msg": verb + key}

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
    """The on-disk .yaml/.star pair for one fqcn. The .yaml is the metadata
    WRITE path (submit()/G8 always write YAML); reads should use
    metadata_path(), which prefers a NestedText sidecar when present."""
    collection, _, name = fqcn.rpartition(".")
    base = Path(modules_dir) / collection
    return base / f"{name}.yaml", base / f"{name}.star"


def metadata_path(modules_dir: str | Path, fqcn: str) -> Path:
    """The metadata sidecar to READ for one fqcn: the `.yaml`.

    NestedText is gone (docs/nestedtext-removal.md) and so is the fallback: measured before removing, the
    library held 0 `.nt` files against 1431 `.yaml`, and the Go agent's loader PREFERRED `.nt` — so a stray
    one would have beaten the file Bossman actually writes.
    """
    collection, _, name = fqcn.rpartition(".")
    return Path(modules_dir) / collection / f"{name}.yaml"


def _as_bool(value: Any, default: bool = False) -> bool:
    """Coerce a metadata boolean. YAML gives a real bool, but a hand-written or older sidecar can carry the
    STRING "false" — and `bool("false")` is True, which would turn a read-only module into a writing one."""
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        low = value.strip().lower()
        if low in ("true", "yes", "on", "1"):
            return True
        if low in ("false", "no", "off", "0"):
            return False
    return default


def _coerce_metadata(meta: dict[str, Any]) -> dict[str, Any]:
    """Coerce the schema's boolean fields (writes, each option's required) from a possible string form.
    Everything else (type, default, choices, descriptions) is legitimately string/list data already."""
    if "writes" in meta:
        meta["writes"] = _as_bool(meta["writes"], True)
    options = meta.get("options")
    if isinstance(options, dict):
        for spec in options.values():
            if isinstance(spec, dict) and "required" in spec:
                spec["required"] = _as_bool(spec["required"])
    return meta


def load_metadata(path: str | Path) -> dict[str, Any]:
    """Read a YAML metadata sidecar, with the schema's booleans coerced."""
    meta = yaml.safe_load(Path(path).read_text(encoding="utf-8")) or {}
    # The coercion STAYS even though YAML gives real booleans: a sidecar written by hand, or produced by an
    # older tool, can still carry `writes: "false"` as a string, and `bool("false")` is True. It costs
    # nothing and it is the difference between a read-only module and one that writes.
    return _coerce_metadata(meta if isinstance(meta, dict) else {})


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


def is_native(meta: dict[str, Any]) -> bool:
    """A NATIVE module is implemented in the agent's Go registry, so it has metadata but no Starlark.
    scripts/generate_builtin_sidecars.py writes these from `agentic-mcpd run-module --list-json`."""
    return _as_bool(meta.get("native"), False)


def list_modules(modules_dir: str | Path, module_sources_dir: str | Path) -> list[dict[str, Any]]:
    """The catalog listing for the module-management UI (Block H4): one entry per known module, cheap by
    design — translated modules are enriched from their small metadata YAML; untranslated ones stay name-only
    (their details load on demand via load_source, never by bulk-reading the 15MB dump).

    Two universes, because there are two kinds of module. The Ansible source dump defines the *translated*
    ones. The agent's **native** Go modules (`apt`, `service`, `file`, …) are not in that dump at all — they
    were never Ansible source — so their sidecars in modules_dir are scanned too. Without that the 65 builtins
    were absent from the catalog entirely and `GET /modules/apt` was a 404."""
    out: list[dict[str, Any]] = []
    for path in sorted(Path(module_sources_dir).glob("*.json")):
        fqcn = path.stem
        collection, _, name = fqcn.rpartition(".")
        entry: dict[str, Any] = {"fqcn": fqcn, "collection": collection, "name": name, "translated": False}
        meta_path = metadata_path(modules_dir, fqcn)
        _, star_path = module_paths(modules_dir, fqcn)
        if meta_path.exists() and star_path.exists():
            entry["translated"] = True
            try:
                meta = load_metadata(meta_path)
                entry["short_description"] = meta.get("short_description", "")
                entry["writes"] = _as_bool(meta.get("writes"), True)
            except (OSError, yaml.YAMLError, ModuleLibraryError):
                pass
        out.append(entry)

    # Native modules: metadata with no Starlark and no source-dump entry.
    seen = {e["fqcn"] for e in out}
    for meta_file in sorted(Path(modules_dir).glob("*/*.yaml")):
        fqcn = f"{meta_file.parent.name}.{meta_file.stem}"
        if fqcn in seen:
            continue
        try:
            meta = load_metadata(meta_file)
        except (OSError, yaml.YAMLError, ModuleLibraryError):
            continue
        if not is_native(meta):
            continue      # a translated module without a dump entry is not our business here
        out.append({
            "fqcn": fqcn, "collection": meta_file.parent.name, "name": meta_file.stem,
            "translated": True, "native": True,
            "short_description": meta.get("short_description", ""),
            "writes": _as_bool(meta.get("writes"), True),
        })
    return out


def load_module(modules_dir: str | Path, fqcn: str) -> dict[str, Any]:
    """One module's stored detail: parsed metadata plus the Starlark source, if it has any.

    A **native** module (`native: true`) is implemented in the agent's Go registry, so requiring a `.star`
    would exclude every builtin — which is exactly why `GET /modules/apt` used to 404 and the Sequence editor
    fell back to a raw JSON box for the most common modules. Its `star` is empty."""
    meta_path = metadata_path(modules_dir, fqcn)
    _, star_path = module_paths(modules_dir, fqcn)
    if not meta_path.exists():
        raise ModuleLibraryError(f"module {fqcn!r} is not in the library")
    if not star_path.exists():
        try:
            meta = load_metadata(meta_path)
        except (OSError, yaml.YAMLError) as exc:
            raise ModuleLibraryError(f"cannot read metadata for {fqcn!r}: {exc}") from exc
        if not is_native(meta):
            raise ModuleLibraryError(f"module {fqcn!r} is not in the library")
        return {"fqcn": fqcn, "metadata": meta, "star": "", "native": True}
    try:
        metadata = load_metadata(meta_path)
        star_code = star_path.read_text(encoding="utf-8")
    except (OSError, yaml.YAMLError) as exc:
        raise ModuleLibraryError(f"cannot read module {fqcn!r}: {exc}") from exc
    return {"fqcn": fqcn, "metadata": metadata, "star_code": star_code}


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
        _, star_path = module_paths(modules_dir, fqcn)
        if metadata_path(modules_dir, fqcn).exists() and star_path.exists():
            entry["translated"] += 1
            translated_total += 1
        else:
            entry["missing"].append(fqcn)
    return {
        "total": len(sources),
        "translated": translated_total,
        "collections": per_collection,
    }
