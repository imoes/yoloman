"""Loads and resolves Bossman plan YAML files (see docs/plan.md's Bossman
plan, section B.5) — a filesystem-native, multi-step extension of the Go
node agent's own tools.d/*.yaml single-task syntax
(internal/tasks/task.go): same `ansible.builtin.<module>:` key,
`params: {type, required, pattern, default}`, and `{{ placeholder }}`
substitution semantics (a string that is *entirely* one placeholder keeps
the argument's native type; a placeholder embedded in a larger string is
stringified) — deliberately kept byte-for-byte compatible so an operator
who already knows tools.d syntax needs nothing new to write a plan step.

What a plan adds on top of a single task: an ordered `steps:` list (each
one a module call, a pipeline, or a file upload), and a
default < host_vars/<hostname>.yaml < explicit-call-params precedence
chain — this is what makes "run plan X against host Y" a minimal
instruction, per the plan's stated goal.
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

ANSIBLE_PREFIX = "ansible.builtin."
_PLACEHOLDER_RE = re.compile(r"\{\{\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}")


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

    module: str | None = None
    body: dict[str, Any] = field(default_factory=dict)
    pipeline: list[list[str]] | None = None
    upload_local_path: str | None = None
    upload_remote_name: str | None = None


@dataclass
class Plan:
    name: str
    description: str
    params: dict[str, ParamSpec]
    steps: list[PlanStep]
    source_path: Path

    def version(self) -> str:
        """A sha256 of the plan file's own bytes — plan_runs.plan_version's
        drift-detection value (see docs/plan.md): "was the plan file
        edited since this run happened", not a hand-maintained version
        number."""
        return hashlib.sha256(self.source_path.read_bytes()).hexdigest()


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

    module_key = None
    module_body = None
    pipeline_raw = raw.get("pipeline")
    upload_raw = raw.get("upload")
    for k, v in raw.items():
        if k in ("name", "check_mode", "on_failure", "pipeline", "upload"):
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
            module=module_key[len(ANSIBLE_PREFIX) :],
            body=module_body or {},
        )
    if pipeline_raw is not None:
        return PlanStep(
            name=name,
            kind="pipeline",
            check_mode=check_mode,
            on_failure=on_failure,
            pipeline=_parse_pipeline_stages(plan_name, name, pipeline_raw),
        )
    if not isinstance(upload_raw, dict) or not upload_raw.get("local_path") or not upload_raw.get("remote_name"):
        raise PlanError(f"plan {plan_name!r}, step {name!r}: 'upload' requires local_path and remote_name")
    return PlanStep(
        name=name,
        kind="upload",
        check_mode=check_mode,
        on_failure=on_failure,
        upload_local_path=upload_raw["local_path"],
        upload_remote_name=upload_raw["remote_name"],
    )


def parse_plan(data: bytes, source_path: Path) -> Plan:
    raw = yaml.safe_load(data)
    if not isinstance(raw, dict):
        raise PlanError(f"{source_path}: plan file must be a YAML mapping")

    name = raw.get("name")
    if not name:
        raise PlanError(f"{source_path}: missing required 'name'")
    description = raw.get("description", "")
    params = _parse_param_specs(name, raw.get("params"))

    steps_raw = raw.get("steps")
    if not isinstance(steps_raw, list) or not steps_raw:
        raise PlanError(f"plan {name!r}: 'steps' must be a non-empty list")
    steps = [_parse_step(name, s) for s in steps_raw]

    return Plan(name=name, description=description, params=params, steps=steps, source_path=source_path)


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


def render_catalog_text(plans_dir: str | Path) -> str:
    """Renders a deterministic, sorted description of every available
    plan — meant to become static, cacheable system-prompt content for
    whatever LLM client drives Bossman's MCP facade (see docs/plan.md's
    Bossman plan, section B.6: Anthropic prompt caching requires the
    cached prefix to be byte-identical across calls, so this must never
    embed a timestamp, UUID, or anything that varies run to run). Given
    the same files on disk, two calls always produce identical text.
    Regenerating this is a deliberate, explicit action (see
    services.catalog.CatalogCache) — never done per tool call."""
    try:
        plans = load_plans_dir(plans_dir)
    except PlanError:
        return "No plans are currently available (the plans directory could not be read)."
    if not plans:
        return "No plans are currently available."

    lines = ["Available plans (call run_plan(plan, host, params, dry_run) to execute one):", ""]
    for plan in sorted(plans, key=lambda p: p.name):
        lines.append(f"- {plan.name}: {plan.description}")
        for pname in sorted(plan.params):
            spec = plan.params[pname]
            requirement = "required" if spec.required else f"default={spec.default!r}"
            lines.append(f"    - {pname} ({spec.type}, {requirement})")
    return "\n".join(lines)


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
