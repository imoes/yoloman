"""Block G11 (NT format, step 1): parse a NestedText runbook or role into a
typed model.

One grammar, two documents (docs/nt-format.md):
- a **role** has a top-level `role:` key — it bundles steps + the monitoring
  (`monitoring.checks`) and alerting (`notifications.routes`) a kind of host
  carries; it's the authoring surface for an OrchestrationPlan.
- everything else is a **runbook** — an ordered procedure you run
  (`yolo-man run …`).

A step is explicit: `name`, `module`, `args` (+ optional `when` / `loop` /
`register` / `ignore_errors`). `run: <cmd>` is sugar for `module: shell` with
`args.cmd`. There is no `become` — the agent runs as root.

Parsing only builds the model + validates shape; variable substitution
(services/nt_vars) and the run engine (step 4) come later. All NestedText
leaves are strings; the few boolean step keys are coerced here.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import nestedtext


class NTRunbookError(Exception):
    """A malformed runbook/role document — carries a human-readable message
    and, for NestedText syntax errors, the 1-based line for editor markers."""

    def __init__(self, message: str, line: int | None = None):
        super().__init__(message)
        self.line = line


def _as_bool(value: Any, default: bool = False) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        low = value.strip().lower()
        if low in ("true", "yes", "on", "1"):
            return True
        if low in ("false", "no", "off", "0"):
            return False
    return default


@dataclass
class Step:
    module: str
    args: dict[str, Any] = field(default_factory=dict)
    name: str = ""
    when: str | None = None
    # a literal list, or a "${var}"-style string resolving to a list at run time
    loop: list[Any] | str | None = None
    register: str | None = None
    # What counts as failure / as a change. Both are Ansible task keywords; they were recognised by the
    # playbook parser (so they were not mistaken for the module key) but never carried into the document,
    # which meant the runner could not honour what the operator wrote.
    failed_when: str | None = None
    changed_when: str | None = None
    ignore_errors: bool = False
    # Ansible task keywords (surface parity). Carried through the canonical doc;
    # `become` is a label (the agent already runs as root), `tags` gates run-time
    # selection, `notify` names handlers (honoured once the engine gains them),
    # `vars` are task-scoped. All optional; omitted from to_dict when unset so
    # existing docs are byte-identical.
    become: bool = False
    tags: list[str] = field(default_factory=list)
    notify: list[str] = field(default_factory=list)
    vars: dict[str, Any] = field(default_factory=dict)
    # block/rescue/always: when module == "block", these hold the child tasks
    # (grouped error handling, Ansible-style). Empty for a normal step.
    block: list["Step"] = field(default_factory=list)
    rescue: list["Step"] = field(default_factory=list)
    always: list["Step"] = field(default_factory=list)

    def _extras(self, d: dict[str, Any]) -> dict[str, Any]:
        if self.when is not None:
            d["when"] = self.when
        if self.register is not None:
            d["register"] = self.register
        if self.ignore_errors:
            d["ignore_errors"] = True
        if self.become:
            d["become"] = True
        if self.tags:
            d["tags"] = self.tags
        if self.notify:
            d["notify"] = self.notify
        if self.vars:
            d["vars"] = self.vars
        return d

    def to_dict(self) -> dict[str, Any]:
        # A block round-trips as block/rescue/always child lists (no module/args).
        if self.module == "block":
            d: dict[str, Any] = {"name": self.name, "block": [s.to_dict() for s in self.block]}
            if self.rescue:
                d["rescue"] = [s.to_dict() for s in self.rescue]
            if self.always:
                d["always"] = [s.to_dict() for s in self.always]
            return self._extras(d)
        # A role call round-trips as the readable `runbook:`/`vars:` form, not
        # module: runbook + args, so the plaintext stays self-explanatory.
        if self.module == "runbook":
            d: dict[str, Any] = {"name": self.name, "runbook": self.args.get("name", "")}
            if self.args.get("vars"):
                d["vars"] = self.args["vars"]
            return self._extras(d)
        d = {"name": self.name, "module": self.module, "args": self.args}
        if self.loop is not None:
            d["loop"] = self.loop
        # These decide what counts as failure / as a change, so they must survive the round-trip — a
        # dropped failed_when means the run silently uses different semantics than the document states.
        if self.failed_when:
            d["failed_when"] = self.failed_when
        if self.changed_when:
            d["changed_when"] = self.changed_when
        return self._extras(d)


@dataclass
class Runbook:
    name: str
    steps: list[Step]
    targets: str | None = None
    # Typed input-mask schema (Block G11-wizard): {name: spec}, see
    # _parse_parameters. Drives the installation-wizard / run-dialog form.
    parameters: dict[str, Any] = field(default_factory=dict)
    # Ansible handlers: named steps run once, at the end, iff a step that
    # `notify`s them reported changed. Optional; empty on legacy docs.
    handlers: list[Step] = field(default_factory=list)

    kind = "runbook"

    def to_dict(self) -> dict[str, Any]:
        d: dict[str, Any] = {"kind": "runbook", "name": self.name, "targets": self.targets,
                             "steps": [s.to_dict() for s in self.steps]}
        if self.parameters:
            d["parameters"] = self.parameters
        if self.handlers:
            d["handlers"] = [h.to_dict() for h in self.handlers]
        return d


@dataclass
class Role:
    name: str
    steps: list[Step]
    description: str = ""
    parameters: dict[str, Any] = field(default_factory=dict)
    checks: list[str] = field(default_factory=list)
    notification_routes: list[str] = field(default_factory=list)

    kind = "role"

    def to_dict(self) -> dict[str, Any]:
        return {"kind": "role", "name": self.name, "description": self.description,
                "parameters": self.parameters, "steps": [s.to_dict() for s in self.steps],
                "monitoring": {"checks": self.checks},
                "notifications": {"routes": self.notification_routes}}


_STEP_KEYS = {"name", "module", "args", "run", "runbook", "vars", "when", "loop", "register", "ignore_errors",
              "failed_when", "changed_when", "become", "tags", "notify", "block", "rescue", "always"}

_PARAM_TYPES = {"string", "number", "bool", "list", "object"}


def _parse_parameters(raw: Any) -> dict[str, Any]:
    """Normalise a `parameters:` block into {name: spec}, where a spec is
    {type, description?, default?, secret?, enum?, items?, hidden?, required?}.
    `boolean` is normalised to `bool`. A value that isn't a typed spec (i.e. not
    a mapping with a `type` key) is passed through unchanged — this keeps the
    legacy free-form Role `parameters` working."""
    if not raw:
        return {}
    if not isinstance(raw, dict):
        raise NTRunbookError("'parameters' must be a mapping of name -> spec")
    out: dict[str, Any] = {}
    for pname, spec in raw.items():
        if not isinstance(spec, dict) or "type" not in spec:
            out[pname] = spec  # legacy / free-form — leave as-is
            continue
        s = dict(spec)
        t = str(s.get("type", "string")).lower()
        if t == "boolean":
            t = "bool"
        if t not in _PARAM_TYPES:
            raise NTRunbookError(f"parameter {pname!r}: unknown type {s.get('type')!r}")
        s["type"] = t
        s["secret"] = _as_bool(s.get("secret"))
        s["hidden"] = _as_bool(s.get("hidden"))
        s["required"] = _as_bool(s.get("required"))
        out[pname] = s
    return out


def _parse_step(raw: Any, idx: int) -> Step:
    if not isinstance(raw, dict):
        raise NTRunbookError(f"step {idx + 1}: must be a mapping, got {type(raw).__name__}")
    unknown = set(raw) - _STEP_KEYS
    if unknown:
        raise NTRunbookError(f"step {idx + 1}: unknown key(s): {', '.join(sorted(unknown))}")

    name = raw.get("name", "")
    if "block" in raw:
        # A block groups child tasks with optional rescue/always error handling.
        if any(k in raw for k in ("module", "args", "run", "runbook", "loop", "register")):
            raise NTRunbookError(f"step {idx + 1} ({name!r}): a 'block' can't also set module/args/run/loop/register")
        block_steps = _parse_steps(raw["block"])
        return Step(
            module="block", name=name, when=raw.get("when"),
            failed_when=raw.get("failed_when"), changed_when=raw.get("changed_when"),
            ignore_errors=_as_bool(raw.get("ignore_errors")),
            become=_as_bool(raw.get("become")), tags=_str_list(raw.get("tags")),
            block=block_steps,
            rescue=_parse_handlers(raw.get("rescue")),
            always=_parse_handlers(raw.get("always")),
        )
    if "runbook" in raw:
        # `runbook: install-nginx` (+ optional `vars:`) — call another stored
        # runbook/role AS A TASK, Ansible import_role-style. Expanded (inlined)
        # before execution by runbook_exec; the agent never sees a "runbook"
        # module. Kept in the doc as module="runbook" so the editor round-trips it.
        if "module" in raw or "args" in raw or "run" in raw:
            raise NTRunbookError(f"step {idx + 1} ({name!r}): 'runbook' is a role call — don't also set module/args/run")
        ref = raw["runbook"]
        if not isinstance(ref, str) or not ref:
            raise NTRunbookError(f"step {idx + 1} ({name!r}): 'runbook' must be a runbook name")
        rvars = raw.get("vars") or {}
        if not isinstance(rvars, dict):
            raise NTRunbookError(f"step {idx + 1} ({name!r}): 'vars' must be a mapping")
        module = "runbook"
        args: dict[str, Any] = {"name": ref, "vars": rvars}
    elif "run" in raw:
        if "module" in raw or "args" in raw:
            raise NTRunbookError(f"step {idx + 1} ({name!r}): 'run' is shorthand for module: shell — don't also set module/args")
        module = "shell"
        args = {"cmd": raw["run"]}
    else:
        module = raw.get("module")
        if not module:
            raise NTRunbookError(f"step {idx + 1} ({name!r}): needs a 'module' (or a 'run:' shell shorthand)")
        args = raw.get("args") or {}
        if not isinstance(args, dict):
            raise NTRunbookError(f"step {idx + 1} ({name!r}): 'args' must be a mapping")

    failed_when = raw.get("failed_when")
    changed_when = raw.get("changed_when")
    loop = raw.get("loop")
    if loop is not None and not isinstance(loop, (list, str)):
        raise NTRunbookError(f"step {idx + 1} ({name!r}): 'loop' must be a list or a ${{var}} string")

    return Step(
        module=module, args=args, name=name,
        when=raw.get("when"), loop=loop, register=raw.get("register"),
        failed_when=failed_when, changed_when=changed_when,
        ignore_errors=_as_bool(raw.get("ignore_errors")),
        become=_as_bool(raw.get("become")),
        tags=_str_list(raw.get("tags")),
        notify=_str_list(raw.get("notify")),
        vars=raw.get("vars") or {} if module != "runbook" else {},
    )


def _parse_steps(raw: Any) -> list[Step]:
    if not isinstance(raw, list) or not raw:
        raise NTRunbookError("'steps' must be a non-empty list")
    return [_parse_step(s, i) for i, s in enumerate(raw)]


def _parse_handlers(raw: Any) -> list[Step]:
    """Handlers are optional and shaped exactly like steps."""
    if raw is None:
        return []
    if not isinstance(raw, list):
        raise NTRunbookError("'handlers' must be a list")
    return [_parse_step(s, i) for i, s in enumerate(raw)]


def _str_list(raw: Any) -> list[str]:
    if raw is None:
        return []
    if isinstance(raw, list):
        return [str(x) for x in raw]
    raise NTRunbookError("expected a list")


def parse_document(text: str, source: str = "<string>") -> Runbook | Role:
    """Parse NestedText into a Runbook or a Role (Role iff it has `role:`)."""
    try:
        data = nestedtext.loads(text, top="dict")
    except nestedtext.NestedTextError as exc:
        line = getattr(exc, "lineno", None)
        raise NTRunbookError(f"{source}: not valid NestedText: {exc}", line=line) from exc
    return parse_data(data, source)


def parse_data(data: Any, source: str = "<data>") -> Runbook | Role:
    """Validate an already-parsed mapping (from NestedText, YAML, or the DB's
    canonical JSON) into a Runbook/Role. The shape rules live here so every
    input format shares one validator."""
    if not isinstance(data, dict):
        raise NTRunbookError(f"{source}: top level must be a mapping")

    if "role" in data:
        return Role(
            name=str(data["role"]),
            description=str(data.get("description", "") or ""),
            parameters=_parse_parameters(data.get("parameters")),
            steps=_parse_steps(data.get("steps")),
            checks=_str_list((data.get("monitoring") or {}).get("checks")),
            notification_routes=_str_list((data.get("notifications") or {}).get("routes")),
        )

    name = data.get("name")
    if not name:
        raise NTRunbookError(f"{source}: a runbook needs a top-level 'name' (or 'role:' for a role)")
    return Runbook(name=str(name), targets=data.get("targets"),
                   parameters=_parse_parameters(data.get("parameters")),
                   steps=_parse_steps(data.get("steps")),
                   handlers=_parse_handlers(data.get("handlers")))


def parse_file(path: str | Path) -> Runbook | Role:
    p = Path(path)
    try:
        text = p.read_text(encoding="utf-8")
    except OSError as exc:
        raise NTRunbookError(f"cannot read {p}: {exc}") from exc
    return parse_document(text, source=str(p))
