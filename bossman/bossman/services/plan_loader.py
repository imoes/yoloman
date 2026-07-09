"""Loads and resolves Bossman plan YAML files (see docs/plan.md's Bossman
plan, section B.5 and the later chunked-plan-caching + Ansible-ingestion
plan) — a filesystem-native, multi-step extension of the Go node agent's
own tools.d/*.yaml single-task syntax (internal/tasks/task.go): same
`ansible.builtin.<module>:` key, `params: {type, required, pattern,
default}`, and `{{ placeholder }}` substitution semantics (a string that
is *entirely* one placeholder keeps the argument's native type; a
placeholder embedded in a larger string is stringified) — deliberately
kept byte-for-byte compatible so an operator who already knows tools.d
syntax needs nothing new to write a plan step.

A plan is an ordered list of **chunks**, each a named group of steps
(`when`/`register`/`check_mode`/`on_failure`, module/pipeline/upload —
see PlanStep) optionally restricted to an `os_family`. Chunking exists for
two reasons: it is the unit an OS-dispatch decision (Ansible's
`include_tasks: "{{ ansible_distribution }}.packages.yml"` pattern) skips
wholesale, and it is the unit a future incremental translator re-hashes
independently (`chunk_id`/`source_hash`) so editing one part of a
translated role doesn't require re-translating the rest. A plain flat
`steps:` list (the pre-chunking syntax) is still valid — it becomes one
implicit, unconditional chunk, so every plan written before chunking
existed keeps working unchanged.
"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

ANSIBLE_PREFIX = "ansible.builtin."
_PLACEHOLDER_RE = re.compile(r"\{\{\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}")

_STEP_META_KEYS = ("name", "check_mode", "on_failure", "when", "register", "pipeline", "upload")


class PlanError(Exception):
    """Raised for any malformed plan file or parameter resolution failure."""


@dataclass
class ParamSpec:
    type: str = "string"
    required: bool = False
    pattern: str | None = None
    default: Any = None


@dataclass
class PlanStep:
    name: str
    kind: str  # "module" | "pipeline" | "upload"
    check_mode: bool = False
    on_failure: str = "abort"  # "abort" | "continue"
    when: str | None = None
    register: str | None = None

    module: str | None = None
    body: dict[str, Any] = field(default_factory=dict)
    pipeline: list[list[str]] | None = None
    upload_local_path: str | None = None
    upload_remote_name: str | None = None

    def canonical_dict(self) -> dict[str, Any]:
        """A plain, JSON-serializable, order-independent representation
        used for chunk_id hashing — every field that defines this step's
        actual behavior, nothing dynamic (no timestamps/run-specific
        data)."""
        return {
            "name": self.name,
            "kind": self.kind,
            "check_mode": self.check_mode,
            "on_failure": self.on_failure,
            "when": self.when,
            "register": self.register,
            "module": self.module,
            "body": self.body,
            "pipeline": self.pipeline,
            "upload_local_path": self.upload_local_path,
            "upload_remote_name": self.upload_remote_name,
        }


@dataclass
class Chunk:
    name: str
    steps: list[PlanStep]
    os_family: list[str] | None = None
    # Hash of the *foreign* source text (e.g. an Ansible role's
    # tasks/debian.packages.yml) this chunk was translated from — None for
    # natively hand-authored Bossman chunks, where there is no separate
    # source to diff against. Set by the (human/AI) translator at
    # authoring time; see chunks_needing_retranslation() below for how
    # it's used to scope a future incremental re-translation to just the
    # chunks whose source actually changed.
    source_hash: str | None = None

    @property
    def chunk_id(self) -> str:
        """Content-addressed id: a sha256 of this chunk's own normalized,
        canonical representation. Identical steps (regardless of which
        file/translation produced them) always hash to the same id."""
        payload = json.dumps(
            {"name": self.name, "os_family": self.os_family, "steps": [s.canonical_dict() for s in self.steps]},
            sort_keys=True,
        )
        return hashlib.sha256(payload.encode()).hexdigest()


@dataclass
class Plan:
    name: str
    description: str
    params: dict[str, ParamSpec]
    chunks: list[Chunk]
    source_path: Path
    # An optional final step run once, after every chunk, only if at least
    # one prior step actually reported changed=True — the normalized form
    # of Ansible's notify/handler pattern (img_docker's "Restart Docker").
    final_handler: PlanStep | None = None

    @property
    def steps(self) -> list[PlanStep]:
        """Flattened view across all chunks, in declaration order — kept
        for callers that only care about "the plan's steps" without
        chunk boundaries (e.g. the REST API's plan-detail step listing)."""
        return [s for c in self.chunks for s in c.steps]

    def version(self) -> str:
        """plan_runs.plan_version's drift-detection value: a hash over
        every chunk's own content-addressed chunk_id, in order. Derived
        entirely from already-parsed, in-memory chunk data — no repeated
        disk read, unlike the original file-bytes-based version()."""
        payload = "|".join(c.chunk_id for c in self.chunks)
        return hashlib.sha256(payload.encode()).hexdigest()


def _parse_param_specs(plan_name: str, raw: Any) -> dict[str, ParamSpec]:
    if raw is None:
        return {}
    if not isinstance(raw, dict):
        raise PlanError(f"plan {plan_name!r}: 'params' must be a mapping")
    specs: dict[str, ParamSpec] = {}
    for pname, raw_spec in raw.items():
        if not isinstance(raw_spec, dict):
            raise PlanError(f"plan {plan_name!r}: params.{pname} must be a mapping")
        spec = ParamSpec(
            type=raw_spec.get("type", "string"),
            required=bool(raw_spec.get("required", False)),
            pattern=raw_spec.get("pattern"),
            default=raw_spec.get("default"),
        )
        if spec.type not in ("string", "bool", "number"):
            raise PlanError(f"plan {plan_name!r}: params.{pname}: unsupported type {spec.type!r}")
        if spec.pattern:
            try:
                re.compile(spec.pattern)
            except re.error as exc:
                raise PlanError(f"plan {plan_name!r}: params.{pname}: invalid pattern: {exc}") from exc
        specs[pname] = spec
    return specs


def _parse_pipeline_stages(plan_name: str, step_name: str, raw: Any) -> list[list[str]]:
    if not isinstance(raw, list) or not raw:
        raise PlanError(f"plan {plan_name!r}, step {step_name!r}: 'pipeline' must be a non-empty list of argv stages")
    stages = []
    for i, stage in enumerate(raw):
        if not isinstance(stage, list) or not stage or not all(isinstance(a, str) for a in stage):
            raise PlanError(f"plan {plan_name!r}, step {step_name!r}: pipeline stage {i} must be a non-empty list of strings")
        stages.append(list(stage))
    return stages


def _parse_step(plan_name: str, raw: dict[str, Any]) -> PlanStep:
    name = raw.get("name")
    if not name:
        raise PlanError(f"plan {plan_name!r}: a step is missing required 'name'")

    check_mode = bool(raw.get("check_mode", False))
    on_failure = raw.get("on_failure", "abort")
    if on_failure not in ("abort", "continue"):
        raise PlanError(f"plan {plan_name!r}, step {name!r}: on_failure must be 'abort' or 'continue'")

    when = raw.get("when")
    if when is not None and not isinstance(when, str):
        raise PlanError(f"plan {plan_name!r}, step {name!r}: 'when' must be a string")

    register = raw.get("register")
    if register is not None and not isinstance(register, str):
        raise PlanError(f"plan {plan_name!r}, step {name!r}: 'register' must be a string")

    module_key = None
    module_body = None
    pipeline_raw = raw.get("pipeline")
    upload_raw = raw.get("upload")
    for k, v in raw.items():
        if k in _STEP_META_KEYS:
            continue
        if not k.startswith(ANSIBLE_PREFIX):
            raise PlanError(f"plan {plan_name!r}, step {name!r}: unexpected key {k!r}")
        if module_key is not None:
            raise PlanError(f"plan {plan_name!r}, step {name!r}: multiple ansible.builtin.* keys")
        if not isinstance(v, dict):
            raise PlanError(f"plan {plan_name!r}, step {name!r}: {k!r} value must be a mapping")
        module_key, module_body = k, v

    kinds_present = sum(x is not None for x in (module_key, pipeline_raw, upload_raw))
    if kinds_present != 1:
        raise PlanError(
            f"plan {plan_name!r}, step {name!r}: exactly one of an ansible.builtin.<module> key, "
            "'pipeline', or 'upload' is required"
        )

    if module_key is not None:
        return PlanStep(
            name=name,
            kind="module",
            check_mode=check_mode,
            on_failure=on_failure,
            when=when,
            register=register,
            module=module_key[len(ANSIBLE_PREFIX) :],
            body=module_body or {},
        )
    if pipeline_raw is not None:
        return PlanStep(
            name=name,
            kind="pipeline",
            check_mode=check_mode,
            on_failure=on_failure,
            when=when,
            register=register,
            pipeline=_parse_pipeline_stages(plan_name, name, pipeline_raw),
        )
    if not isinstance(upload_raw, dict) or not upload_raw.get("local_path") or not upload_raw.get("remote_name"):
        raise PlanError(f"plan {plan_name!r}, step {name!r}: 'upload' requires local_path and remote_name")
    return PlanStep(
        name=name,
        kind="upload",
        check_mode=check_mode,
        on_failure=on_failure,
        when=when,
        register=register,
        upload_local_path=upload_raw["local_path"],
        upload_remote_name=upload_raw["remote_name"],
    )


def _parse_chunk(plan_name: str, raw: dict[str, Any]) -> Chunk:
    if not isinstance(raw, dict):
        raise PlanError(f"plan {plan_name!r}: each chunk must be a mapping")
    name = raw.get("name")
    if not name:
        raise PlanError(f"plan {plan_name!r}: a chunk is missing required 'name'")

    os_family = raw.get("os_family")
    if os_family is not None and (not isinstance(os_family, list) or not all(isinstance(x, str) for x in os_family)):
        raise PlanError(f"plan {plan_name!r}, chunk {name!r}: 'os_family' must be a list of strings")

    source_hash = raw.get("source_hash")
    if source_hash is not None and not isinstance(source_hash, str):
        raise PlanError(f"plan {plan_name!r}, chunk {name!r}: 'source_hash' must be a string")

    steps_raw = raw.get("steps")
    if not isinstance(steps_raw, list) or not steps_raw:
        raise PlanError(f"plan {plan_name!r}, chunk {name!r}: 'steps' must be a non-empty list")

    return Chunk(
        name=name,
        steps=[_parse_step(plan_name, s) for s in steps_raw],
        os_family=os_family,
        source_hash=source_hash,
    )


def parse_plan(data: bytes, source_path: Path) -> Plan:
    """Parse a YAML plan file. The format-specific step (YAML → dict) is the
    only thing here; everything downstream is shared with parse_plan_nt (the
    NestedText front-end) via build_plan_from_raw, so both syntaxes produce
    identical Plan/Chunk/PlanStep structures."""
    raw = yaml.safe_load(data)
    if not isinstance(raw, dict):
        raise PlanError(f"{source_path}: plan file must be a YAML mapping")
    return build_plan_from_raw(raw, source_path)


def build_plan_from_raw(raw: dict[str, Any], source_path: Path) -> Plan:
    """Build a Plan from an already-parsed mapping (dict of str→…), whatever
    front-end produced it (PyYAML or NestedText). Format-agnostic: this is
    the single place the plan schema is validated and assembled."""
    name = raw.get("name")
    if not name:
        raise PlanError(f"{source_path}: missing required 'name'")
    description = raw.get("description", "")
    params = _parse_param_specs(name, raw.get("params"))

    chunks_raw = raw.get("chunks")
    steps_raw = raw.get("steps")
    if chunks_raw is not None and steps_raw is not None:
        raise PlanError(f"plan {name!r}: specify either 'chunks' or 'steps', not both")

    if chunks_raw is not None:
        if not isinstance(chunks_raw, list) or not chunks_raw:
            raise PlanError(f"plan {name!r}: 'chunks' must be a non-empty list")
        chunks = [_parse_chunk(name, c) for c in chunks_raw]
    elif steps_raw is not None:
        # Backward-compatible shorthand: a flat steps: list is one
        # implicit, unconditional chunk.
        if not isinstance(steps_raw, list) or not steps_raw:
            raise PlanError(f"plan {name!r}: 'steps' must be a non-empty list")
        chunks = [Chunk(name="main", steps=[_parse_step(name, s) for s in steps_raw])]
    else:
        raise PlanError(f"plan {name!r}: must have either 'chunks' or 'steps'")

    final_handler = None
    handler_raw = raw.get("final_handler")
    if handler_raw is not None:
        if not isinstance(handler_raw, dict):
            raise PlanError(f"plan {name!r}: 'final_handler' must be a mapping")
        final_handler = _parse_step(name, handler_raw)

    return Plan(
        name=name,
        description=description,
        params=params,
        chunks=chunks,
        source_path=source_path,
        final_handler=final_handler,
    )


def load_plan_file(path: str | Path) -> Plan:
    path = Path(path)
    return parse_plan(path.read_bytes(), path)


def load_plans_dir(plans_dir: str | Path) -> list[Plan]:
    """Loads every *.yaml/*.yml file directly under plans_dir (not
    recursively — host_vars/ and files/ are conventional subdirectories,
    not plans themselves) into a Plan, erroring on duplicate names. A
    missing directory yields no plans rather than erroring — matches the
    Go tools.d loader's "optional directory" behavior."""
    plans_dir = Path(plans_dir)
    if not plans_dir.is_dir():
        return []

    paths = sorted(p for p in plans_dir.iterdir() if p.is_file() and p.suffix in (".yaml", ".yml"))
    seen: dict[str, Path] = {}
    plans = []
    for path in paths:
        plan = load_plan_file(path)
        if plan.name in seen:
            raise PlanError(f"{path}: duplicate plan name {plan.name!r} (already defined in {seen[plan.name]})")
        seen[plan.name] = path
        plans.append(plan)
    return plans


def render_catalog_markdown(plans: list[Plan]) -> str:
    """Renders a deterministic Markdown catalog of already-parsed plans —
    meant to become static, cacheable system-prompt content for whatever
    LLM client drives Bossman's MCP facade (see docs/plan.md's Bossman
    plan: Anthropic prompt caching requires the cached prefix to be
    byte-identical across calls, so this must never embed a timestamp,
    UUID, or the target host — the host is always a tool-call argument,
    never described here). Given the same plans, two calls always produce
    identical text.

    Markdown, not JSON: caching is prefix-based (Tools -> System ->
    Messages), so the block's *format* doesn't affect whether a cache hit
    happens, only how many tokens the cached prefix costs — and Markdown
    measurably costs fewer tokens than JSON for this prose-heavy content
    (plan descriptions stay as the plan author's own prose). The
    machine-facing `list_plans` MCP tool / REST route return JSON from
    the same parsed Plan objects, computed once, not re-derived from this
    text.

    Deliberately excludes step bodies — this is a "what plans exist and
    what do they need" catalog, not an execution log. Full step detail is
    on-demand via get_plan/get_plan_run, which don't need to be part of
    the cached prefix.
    """
    if not plans:
        return "_No plans are currently available._\n"

    lines = [
        "# Available plans",
        "",
        "Call `run_plan(plan, host, params, dry_run)` to execute one. `host` is always a tool-call "
        "argument, never named in this catalog, so the catalog stays identical no matter which host "
        "you target.",
        "",
    ]
    for plan in sorted(plans, key=lambda p: p.name):
        lines.append(f"## {plan.name}")
        lines.append("")
        lines.append(plan.description or "_No description._")
        if plan.params:
            lines.append("")
            lines.append("Params:")
            for pname in sorted(plan.params):
                spec = plan.params[pname]
                requirement = "required" if spec.required else f"default={spec.default!r}"
                lines.append(f"- `{pname}` ({spec.type}, {requirement})")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def load_host_vars(plans_dir: str | Path, hostname: str) -> dict[str, Any]:
    """Loads plans_dir/host_vars/<hostname>.yaml if it exists, else {}."""
    path = Path(plans_dir) / "host_vars" / f"{hostname}.yaml"
    if not path.is_file():
        return {}
    data = yaml.safe_load(path.read_bytes())
    if data is None:
        return {}
    if not isinstance(data, dict):
        raise PlanError(f"{path}: host_vars file must be a YAML mapping")
    return data


def resolve_params(plan: Plan, host_vars: dict[str, Any], explicit: dict[str, Any]) -> dict[str, Any]:
    """Merges plan.params.default < host_vars < explicit (in that
    precedence — later sources win), validating required/type/pattern and
    rejecting unknown keys, mirroring the Go tools.d parser's buildArgs."""
    merged_given = {**host_vars, **explicit}
    args: dict[str, Any] = {}
    for pname, spec in plan.params.items():
        if pname in merged_given:
            value = merged_given[pname]
            if spec.type == "string":
                if not isinstance(value, str):
                    raise PlanError(f"{pname}: expected string, got {type(value).__name__}")
                if spec.pattern and not re.match(spec.pattern, value):
                    raise PlanError(f"{pname}: value {value!r} does not match required pattern {spec.pattern!r}")
            elif spec.type == "bool":
                if not isinstance(value, bool):
                    raise PlanError(f"{pname}: expected bool, got {type(value).__name__}")
            elif spec.type == "number":
                if isinstance(value, bool) or not isinstance(value, int | float):
                    raise PlanError(f"{pname}: expected number, got {type(value).__name__}")
            args[pname] = value
        elif spec.required:
            raise PlanError(f"{pname}: missing required parameter")
        elif spec.default is not None:
            args[pname] = spec.default

    unknown = set(merged_given) - set(plan.params)
    if unknown:
        raise PlanError(f"unknown parameter(s): {', '.join(sorted(unknown))}")
    return args


def substitute(val: Any, args: dict[str, Any]) -> Any:
    """Walks val (a step body value: str, dict, or list) replacing every
    "{{ name }}" with args[name]. A string that is *entirely* one
    placeholder is replaced with the argument's native type; an embedded
    placeholder is stringified. An unresolved reference is an error."""
    if isinstance(val, str):
        trimmed = val.strip()
        whole_match = _PLACEHOLDER_RE.fullmatch(trimmed)
        if whole_match:
            pname = whole_match.group(1)
            if pname not in args:
                raise PlanError(f"unresolved parameter reference {{{{ {pname} }}}}")
            return args[pname]

        def _replace(m: re.Match) -> str:
            pname = m.group(1)
            if pname not in args:
                raise PlanError(f"unresolved parameter reference {{{{ {pname} }}}}")
            return str(args[pname])

        return _PLACEHOLDER_RE.sub(_replace, val)
    if isinstance(val, dict):
        return {k: substitute(v, args) for k, v in val.items()}
    if isinstance(val, list):
        return [substitute(v, args) for v in val]
    return val


def chunks_needing_retranslation(existing_chunks: list[Chunk], current_source_hashes: dict[str, str]) -> list[str]:
    """The incremental-retranslation scaffold: given the chunks already
    persisted for a plan and a fresh `{chunk_name: source_hash}` map
    computed from the *current* foreign source (an Ansible role's task
    files, re-hashed), returns the names of chunks whose source actually
    changed (or that are new) — the only ones a future translator would
    need to re-run an LLM/parser over. Chunks whose source_hash still
    matches are left untouched, proving the "don't recompute what hasn't
    changed" mechanism independent of any real orchestrator parser, which
    is future work.

    A chunk with no source_hash (natively hand-authored, no foreign
    source) is never flagged — there's nothing to diff it against.
    """
    existing_by_name = {c.name: c for c in existing_chunks if c.source_hash is not None}
    stale = []
    for chunk_name, source_hash in current_source_hashes.items():
        existing = existing_by_name.get(chunk_name)
        if existing is None or existing.source_hash != source_hash:
            stale.append(chunk_name)
    return sorted(stale)


def hash_source_text(text: str) -> str:
    """sha256 of a foreign source excerpt (e.g. one Ansible task file's
    raw bytes) — the value a (human/AI) translator computes once at
    authoring time and pastes into a chunk's `source_hash:` field."""
    return hashlib.sha256(text.encode()).hexdigest()
