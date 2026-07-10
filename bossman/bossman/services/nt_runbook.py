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
    ignore_errors: bool = False

    def to_dict(self) -> dict[str, Any]:
        d: dict[str, Any] = {"name": self.name, "module": self.module, "args": self.args}
        if self.when is not None:
            d["when"] = self.when
        if self.loop is not None:
            d["loop"] = self.loop
        if self.register is not None:
            d["register"] = self.register
        if self.ignore_errors:
            d["ignore_errors"] = True
        return d


@dataclass
class Runbook:
    name: str
    steps: list[Step]
    targets: str | None = None

    kind = "runbook"

    def to_dict(self) -> dict[str, Any]:
        return {"kind": "runbook", "name": self.name, "targets": self.targets,
                "steps": [s.to_dict() for s in self.steps]}


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


_STEP_KEYS = {"name", "module", "args", "run", "when", "loop", "register", "ignore_errors"}


def _parse_step(raw: Any, idx: int) -> Step:
    if not isinstance(raw, dict):
        raise NTRunbookError(f"step {idx + 1}: must be a mapping, got {type(raw).__name__}")
    unknown = set(raw) - _STEP_KEYS
    if unknown:
        raise NTRunbookError(f"step {idx + 1}: unknown key(s): {', '.join(sorted(unknown))}")

    name = raw.get("name", "")
    if "run" in raw:
        if "module" in raw or "args" in raw:
            raise NTRunbookError(f"step {idx + 1} ({name!r}): 'run' is shorthand for module: shell — don't also set module/args")
        module = "shell"
        args: dict[str, Any] = {"cmd": raw["run"]}
    else:
        module = raw.get("module")
        if not module:
            raise NTRunbookError(f"step {idx + 1} ({name!r}): needs a 'module' (or a 'run:' shell shorthand)")
        args = raw.get("args") or {}
        if not isinstance(args, dict):
            raise NTRunbookError(f"step {idx + 1} ({name!r}): 'args' must be a mapping")

    loop = raw.get("loop")
    if loop is not None and not isinstance(loop, (list, str)):
        raise NTRunbookError(f"step {idx + 1} ({name!r}): 'loop' must be a list or a ${{var}} string")

    return Step(
        module=module, args=args, name=name,
        when=raw.get("when"), loop=loop, register=raw.get("register"),
        ignore_errors=_as_bool(raw.get("ignore_errors")),
    )


def _parse_steps(raw: Any) -> list[Step]:
    if not isinstance(raw, list) or not raw:
        raise NTRunbookError("'steps' must be a non-empty list")
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
            parameters=data.get("parameters") or {},
            steps=_parse_steps(data.get("steps")),
            checks=_str_list((data.get("monitoring") or {}).get("checks")),
            notification_routes=_str_list((data.get("notifications") or {}).get("routes")),
        )

    name = data.get("name")
    if not name:
        raise NTRunbookError(f"{source}: a runbook needs a top-level 'name' (or 'role:' for a role)")
    return Runbook(name=str(name), targets=data.get("targets"), steps=_parse_steps(data.get("steps")))


def parse_file(path: str | Path) -> Runbook | Role:
    p = Path(path)
    try:
        text = p.read_text(encoding="utf-8")
    except OSError as exc:
        raise NTRunbookError(f"cannot read {p}: {exc}") from exc
    return parse_document(text, source=str(p))
