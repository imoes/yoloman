"""Ansible-task YAML ↔ canonical runbook doc (Block G11, Ansible-syntax surface).

We offer real Ansible **task** syntax as the authoring/interchange format while
keeping the Go agent + Starlark runtime. A task is module-as-key
(`ansible.builtin.copy: {src, dest}`) plus task keywords (when/loop/register/
become/tags/notify/vars/…). This parses that into the SAME canonical doc the
NestedText parser produces (services/nt_runbook), so execution is unchanged.

Structure = a **task list** (one implicit play): either a bare YAML list of
tasks, or a mapping `{name?, targets?/hosts?, tasks: [...]}`. Multi-play
playbooks, block/rescue/always and handlers are intentionally out of scope here
(the engine gains block/handlers/notify in a later phase); a task carrying
`block`/`rescue`/`always` raises a clear error for now.
"""

from __future__ import annotations

from typing import Any

import yaml

from bossman.services.nt_runbook import Runbook, Step, _as_bool, _str_list


class PlaybookError(Exception):
    """A playbook that isn't a shape we can map to the canonical doc."""


# Task-level keywords we recognise; everything else on a task is treated as the
# module key (Ansible's own rule: the module is the key that isn't a keyword).
_TASK_KEYWORDS = {
    "name", "when", "loop", "with_items", "register", "ignore_errors",
    "become", "tags", "notify", "vars", "args",
}
# Free-form modules whose scalar value is the command (`shell: echo hi`).
_FREE_FORM = {"shell", "command", "raw", "script", "ansible.builtin.shell",
              "ansible.builtin.command", "ansible.builtin.raw", "ansible.builtin.script"}
# Not supported by the task-list surface yet — fail loudly rather than silently drop.
# (handlers ARE supported, as a sibling `handlers:` section — not a task key.)
_UNSUPPORTED = {"block", "rescue", "always"}
# Role/task includes → our runbook-call step (module="runbook").
_ROLE_CALL_KEYS = {"import_tasks", "include_tasks", "import_role", "include_role"}


def _norm_module(key: str) -> str:
    """The registry key the Go agent uses: native builtins by short name
    (ansible.builtin.copy → copy), collection modules by fqcn (kept as-is)."""
    return key[len("ansible.builtin."):] if key.startswith("ansible.builtin.") else key


def _task_to_step(task: Any, idx: int) -> Step:
    if not isinstance(task, dict):
        raise PlaybookError(f"task {idx + 1}: must be a mapping, got {type(task).__name__}")
    bad = _UNSUPPORTED & set(task)
    if bad:
        raise PlaybookError(f"task {idx + 1}: '{', '.join(sorted(bad))}' not supported yet (coming with the engine's block/handler phase)")

    module_keys = [k for k in task if k not in _TASK_KEYWORDS]
    if not module_keys:
        raise PlaybookError(f"task {idx + 1}: no module key (a task needs exactly one module, e.g. `copy:`)")
    if len(module_keys) > 1:
        raise PlaybookError(f"task {idx + 1}: ambiguous — more than one non-keyword key: {', '.join(sorted(module_keys))}")
    mkey = module_keys[0]
    module = _norm_module(mkey)

    # import_tasks/include_tasks/import_role/include_role → our runbook-call step
    # (module="runbook", args.name = the referenced runbook/role).
    if mkey in _ROLE_CALL_KEYS:
        ref = task[mkey]
        ref = ref if isinstance(ref, str) else (ref or {}).get("name", "") if isinstance(ref, dict) else ""
        return Step(module="runbook", args={"name": ref, "vars": task.get("vars") or {}},
                    name=task.get("name", ""),
                    when=(str(task["when"]) if task.get("when") is not None else None),
                    register=task.get("register"), ignore_errors=_as_bool(task.get("ignore_errors")))

    raw_val = task[mkey]
    if isinstance(raw_val, dict):
        args: dict[str, Any] = dict(raw_val)
    elif raw_val is None or raw_val == "":
        args = {}
    elif isinstance(raw_val, str):
        if mkey in _FREE_FORM:
            args = {"cmd": raw_val}
        else:
            raise PlaybookError(f"task {idx + 1} ({module}): scalar free-form value is only allowed for shell/command/raw/script")
    else:
        raise PlaybookError(f"task {idx + 1} ({module}): module value must be a mapping (or a command string for shell/command)")
    # `args:` sibling merges over the free-form/base args (Ansible semantics).
    extra = task.get("args")
    if isinstance(extra, dict):
        args.update(extra)

    loop = task.get("loop", task.get("with_items"))
    if loop is not None and not isinstance(loop, (list, str)):
        raise PlaybookError(f"task {idx + 1} ({module}): 'loop'/'with_items' must be a list or a template string")

    tvars = task.get("vars") or {}
    if not isinstance(tvars, dict):
        raise PlaybookError(f"task {idx + 1} ({module}): 'vars' must be a mapping")

    return Step(
        module=module, args=args, name=task.get("name", ""),
        when=(str(task["when"]) if task.get("when") is not None else None),
        loop=loop, register=task.get("register"),
        ignore_errors=_as_bool(task.get("ignore_errors")),
        become=_as_bool(task.get("become")),
        tags=_str_list(task.get("tags")),
        notify=_str_list(task.get("notify")),
        vars=tvars,
    )


def parse_playbook(text: str) -> Runbook:
    """Ansible-task YAML → a Runbook (same object parse_document returns, so the
    lint/run endpoints handle it uniformly). Accepts a bare task list, or a
    `{name?, targets?/hosts?, tasks: [...]}` mapping, or a single-play list
    `[{hosts?, name?, tasks: [...]}]` (first play only; more raise)."""
    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        raise PlaybookError(f"invalid YAML: {exc}") from exc
    if data is None:
        raise PlaybookError("empty playbook")

    name = ""
    targets: str | None = None
    tasks: Any
    handlers_raw: Any = None

    if isinstance(data, dict) and "tasks" in data:
        name = data.get("name", "") or ""
        targets = data.get("targets") or data.get("hosts")
        tasks = data.get("tasks")
        handlers_raw = data.get("handlers")
    elif isinstance(data, list) and data and isinstance(data[0], dict) and "tasks" in data[0]:
        # a plays list — task-list surface supports a single play
        if len(data) > 1:
            raise PlaybookError("multiple plays are not supported (task-list mode); use one play or a bare task list")
        play = data[0]
        name = play.get("name", "") or ""
        targets = play.get("hosts") or play.get("targets")
        tasks = play.get("tasks")
        handlers_raw = play.get("handlers")
    elif isinstance(data, list):
        tasks = data
    else:
        raise PlaybookError("expected a task list or a {tasks: [...]} mapping")

    if not isinstance(tasks, list) or not tasks:
        raise PlaybookError("'tasks' must be a non-empty list")
    if handlers_raw is not None and not isinstance(handlers_raw, list):
        raise PlaybookError("'handlers' must be a list")

    targets = str(targets) if targets is not None else None
    steps = [_task_to_step(t, i) for i, t in enumerate(tasks)]
    handlers = [_task_to_step(h, i) for i, h in enumerate(handlers_raw or [])]
    return Runbook(name=name, steps=steps, targets=targets, handlers=handlers)


def _step_to_task(step: dict[str, Any]) -> dict[str, Any]:
    """One canonical doc step → an Ansible task dict (module-as-key). Handles the
    loose NestedText sugar some stored docs carry (a step with `run:` or
    `runbook:` instead of `module:` — e.g. wizard-seeded runbooks)."""
    task: dict[str, Any] = {}
    if step.get("name"):
        task["name"] = step["name"]
    module = step.get("module", "")
    if module == "runbook" or (not module and "runbook" in step):
        # a role/runbook call has no agent module — an import_tasks-style reference
        ref = step["runbook"] if "runbook" in step else step.get("args", {}).get("name", "")
        task["import_tasks"] = ref
    elif not module and "run" in step:
        # `run: <cmd>` shorthand → the shell module. Emit the DICT form
        # (shell: {cmd: …}) not a scalar: the block importer maps args by key,
        # and a bare scalar free-form would fall back to a raw_task block.
        task["shell"] = {"cmd": step["run"]}
    else:
        task[module or "shell"] = step.get("args", {}) or {}
    for key in ("when", "loop", "register", "ignore_errors", "become", "tags", "notify", "vars"):
        if key in step and step[key] not in (None, [], {}, False):
            task[key] = step[key]
    return task


def doc_to_playbook(doc: dict[str, Any]) -> str:
    """Canonical doc → Ansible-task YAML (a `{name, targets, tasks: [...]}`
    envelope carrying our name/targets metadata + a real Ansible task list)."""
    tasks = [_step_to_task(s) for s in (doc.get("steps") or [])]
    out: dict[str, Any] = {}
    if doc.get("name"):
        out["name"] = doc["name"]
    if doc.get("targets"):
        out["targets"] = doc["targets"]
    out["tasks"] = tasks
    if doc.get("handlers"):
        out["handlers"] = [_step_to_task(h) for h in doc["handlers"]]
    return yaml.safe_dump(out, sort_keys=False, default_flow_style=False, allow_unicode=True)
