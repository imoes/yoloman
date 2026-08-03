"""Ansible-task YAML ↔ canonical runbook doc — **the** authoring format.

Real Ansible **task** syntax is the only text format the system reads or writes; the runtime stays the Go
agent + Starlark. A task is module-as-key (`ansible.builtin.copy: {src, dest}`) plus task keywords
(when/loop/register/become/tags/notify/…), parsed into the canonical doc model in services/nt_runbook, so
execution is unchanged. (A NestedText surface existed alongside this one and was removed — two authoring
formats meant two grammars to keep correct, and only one of them was a format anyone else can read.)

Structure = a **task list** (one implicit play): a bare YAML list of tasks, or a mapping
`{name?, targets?/hosts?, tasks: [...], handlers?: [...]}`, or a **role**: `{role, tasks, monitoring.checks?,
notifications.routes?}`. Supported: module-as-key tasks, `key=value` free-form, when/loop/register/become/
tags/notify/vars, `block`/`rescue`/`always`, `set_fact`, role/task includes, `handlers:`. Out of scope:
multi-play playbooks, dynamic includes, strategy/lookup plugins.
"""

from __future__ import annotations

from typing import Any

import yaml

from bossman.services.nt_runbook import Role, Runbook, Step, _as_bool, _parse_parameters, _str_list


class PlaybookError(Exception):
    """A playbook that isn't a shape we can map to the canonical doc."""


# Task-level keywords we recognise; everything else on a task is treated as the
# module key (Ansible's own rule: the module is the key that isn't a keyword).
_TASK_KEYWORDS = {
    "name", "when", "loop", "with_items", "register", "ignore_errors",
    "become", "tags", "notify", "vars", "args",
    "block", "rescue", "always",
    # Recognised standard Ansible task keywords. Not all are honoured by our
    # engine yet, but they must NOT be mistaken for the module key (otherwise a
    # perfectly valid task reads as "ambiguous, two module keys"). Unhandled
    # ones are carried through the doc opaquely / ignored at run time.
    "changed_when", "failed_when", "delegate_to", "delegate_facts", "run_once",
    "no_log", "check_mode", "environment", "retries", "until", "delay",
    "throttle", "listen", "become_user", "become_method", "any_errors_fatal",
}
# Free-form modules whose scalar value is the command (`shell: echo hi`).
_FREE_FORM = {"shell", "command", "raw", "script", "ansible.builtin.shell",
              "ansible.builtin.command", "ansible.builtin.raw", "ansible.builtin.script"}
# Reserved task keys handled specially below (block error-handling, handlers).
# `rescue`/`always` only ever appear as siblings of `block`.
# Role/task includes → our runbook-call step (module="runbook").
_ROLE_CALL_KEYS = {"import_tasks", "include_tasks", "import_role", "include_role"}


# Modules whose free-form scalar has ONE documented meaning, so the shorthand can be expanded safely.
# Anything not listed here would land in Ansible's `_raw_params`, which only the module itself can decode —
# guessing there would silently run a different task than the author wrote.
_BARE_VALUE_ARG = {
    "include_vars": "file", "ansible.builtin.include_vars": "file",
    "debug": "msg", "ansible.builtin.debug": "msg",
}
# Ansible's boolean literals. k=v form carries no types (everything is a string), and Ansible's own argspec
# coerces these tokens per module — so a bare `update_cache=yes` must become True or the module rejects it.
_KV_TRUE = {"yes", "true", "on"}
_KV_FALSE = {"no", "false", "off"}


def _parse_key_value(text: str, idx: int, module: str) -> dict[str, Any]:
    """Ansible's `key=value key2="v 2"` free-form task syntax → an args mapping.

    Every module accepts this form (`apt: update_cache=yes cache_valid_time=86400`), and real roles use it
    constantly, so refusing it means refusing most upstream Ansible. shlex handles the quoting rules; the
    value coercion below is deliberately narrow (only Ansible's own boolean literals and plain integers)
    because k=v is untyped and blindly guessing types would corrupt string arguments.
    """
    import shlex

    try:
        tokens = shlex.split(text)
    except ValueError as exc:                                       # unbalanced quotes
        raise PlaybookError(f"task {idx + 1} ({module}): cannot parse key=value form: {exc}") from exc
    args: dict[str, Any] = {}
    for token in tokens:
        if "=" not in token:
            raise PlaybookError(
                f"task {idx + 1} ({module}): {token!r} in the key=value form has no '=' — mixing a bare "
                "value with key=value pairs is not supported (Ansible would pass it as _raw_params)")
        key, _, value = token.partition("=")
        low = value.lower()
        if low in _KV_TRUE:
            args[key] = True
        elif low in _KV_FALSE:
            args[key] = False
        elif value.lstrip("-").isdigit():
            args[key] = int(value)
        else:
            args[key] = value
    return args


def _norm_module(key: str) -> str:
    """The registry key the Go agent uses: native builtins by short name
    (ansible.builtin.copy → copy), collection modules by fqcn (kept as-is)."""
    return key[len("ansible.builtin."):] if key.startswith("ansible.builtin.") else key


def _task_to_step(task: Any, idx: int) -> Step:
    if not isinstance(task, dict):
        raise PlaybookError(f"task {idx + 1}: must be a mapping, got {type(task).__name__}")

    # block/rescue/always: grouped error handling. `block` is a list of tasks;
    # `rescue`/`always` are optional sibling task lists.
    if "block" in task:
        if not isinstance(task["block"], list):
            raise PlaybookError(f"task {idx + 1}: 'block' must be a list of tasks")
        return Step(
            module="block", name=task.get("name", ""),
            when=(str(task["when"]) if task.get("when") is not None else None),
            ignore_errors=_as_bool(task.get("ignore_errors")),
            failed_when=task.get("failed_when"), changed_when=task.get("changed_when"),
            become=_as_bool(task.get("become")), tags=_str_list(task.get("tags")),
            block=[_task_to_step(t, i) for i, t in enumerate(task["block"])],
            rescue=[_task_to_step(t, i) for i, t in enumerate(task.get("rescue") or [])],
            always=[_task_to_step(t, i) for i, t in enumerate(task.get("always") or [])],
        )

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
                    register=task.get("register"), ignore_errors=_as_bool(task.get("ignore_errors")),
                    failed_when=task.get("failed_when"), changed_when=task.get("changed_when"))

    raw_val = task[mkey]
    if isinstance(raw_val, dict):
        args: dict[str, Any] = dict(raw_val)
    elif raw_val is None or raw_val == "":
        args = {}
    elif isinstance(raw_val, str):
        if mkey in _FREE_FORM:
            args = {"cmd": raw_val}
        elif mkey in _BARE_VALUE_ARG:
            # A module whose free-form scalar has a documented meaning (`include_vars: x.yml` == `file: x.yml`).
            args = {_BARE_VALUE_ARG[mkey]: raw_val}
        elif "=" in raw_val:
            args = _parse_key_value(raw_val, idx, module)
        else:
            raise PlaybookError(
                f"task {idx + 1} ({module}): scalar free-form value is only allowed for shell/command/raw/"
                f"script, as `key=value` pairs, or for modules with a documented bare argument — Ansible "
                f"would pass {raw_val!r} as _raw_params, which only the module itself can interpret")
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
            failed_when=task.get("failed_when"), changed_when=task.get("changed_when"),
        become=_as_bool(task.get("become")),
        tags=_str_list(task.get("tags")),
        notify=_str_list(task.get("notify")),
        vars=tvars,
    )


def parse_playbook(text: str) -> Runbook | Role:
    """Ansible-task YAML → a Runbook (or a Role), so the lint/run endpoints handle every document uniformly.

    Accepts a bare task list, a `{name?, targets?/hosts?, tasks: [...]}` mapping, or a single-play list
    `[{hosts?, name?, tasks: [...]}]` (first play only; more raise).

    A **role** is the same task syntax under a `role:` key, plus the two envelope sections a role owns —
    `monitoring.checks` and `notifications.routes` ("what is orchestrated is monitored"). Ansible has no
    concept for those, so they are ours, exactly like `targets:`; the tasks inside are plain Ansible.
    """
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

    if isinstance(data, dict) and "role" in data:
        role_tasks = data.get("tasks")
        if not isinstance(role_tasks, list) or not role_tasks:
            raise PlaybookError("a role needs a non-empty 'tasks' list")
        return Role(
            name=str(data["role"]),
            description=str(data.get("description", "") or ""),
            parameters=_parse_parameters(data.get("parameters")),
            steps=[_task_to_step(t, i) for i, t in enumerate(role_tasks)],
            checks=_str_list((data.get("monitoring") or {}).get("checks")),
            notification_routes=_str_list((data.get("notifications") or {}).get("routes")),
        )

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
    return Runbook(name=name, steps=steps, targets=targets, handlers=handlers,
                   parameters=_parse_parameters(data.get("parameters")) if isinstance(data, dict) else {})


def _step_to_task(step: dict[str, Any]) -> dict[str, Any]:
    """One canonical doc step → an Ansible task dict (module-as-key). Handles the
    shorthand some stored docs carry (a step with `run:` or
    `runbook:` instead of `module:` — e.g. wizard-seeded runbooks)."""
    task: dict[str, Any] = {}
    if step.get("name"):
        task["name"] = step["name"]
    module = step.get("module", "")
    # A block canonical step carries block/rescue/always child-step lists.
    if module == "block" or (not module and "block" in step):
        task["block"] = [_step_to_task(c) for c in step.get("block", [])]
        if step.get("rescue"):
            task["rescue"] = [_step_to_task(c) for c in step["rescue"]]
        if step.get("always"):
            task["always"] = [_step_to_task(c) for c in step["always"]]
        for key in ("when", "become", "tags", "ignore_errors", "failed_when", "changed_when"):
            if key in step and step[key] not in (None, [], {}, False):
                task[key] = step[key]
        return task
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
    # failed_when / changed_when belong here too: they decide what counts as failure and as a change, so
    # omitting them on the way out would hand back a playbook that runs differently than the one imported.
    for key in ("when", "loop", "register", "ignore_errors", "failed_when", "changed_when",
                "become", "tags", "notify", "vars"):
        if key in step and step[key] not in (None, [], {}, False):
            task[key] = step[key]
    return task


def doc_to_playbook(doc: dict[str, Any]) -> str:
    """Canonical doc → Ansible-task YAML: a `{name|role, targets?, tasks: [...]}` envelope carrying our own
    metadata plus a real Ansible task list.

    A **role** must render with its `role:` key and its `monitoring`/`notifications` sections. Emitting a role
    as `{name, tasks}` would round-trip it into a *runbook*: the text view is editable, so saving what was
    rendered would silently drop the role's checks and notification routes — the same identity loss that
    `parse_data` had in the other direction."""
    tasks = [_step_to_task(s) for s in (doc.get("steps") or [])]
    out: dict[str, Any] = {}
    is_role = doc.get("kind") == "role"
    if is_role:
        out["role"] = doc.get("name", "")
        if doc.get("description"):
            out["description"] = doc["description"]
    elif doc.get("name"):
        out["name"] = doc["name"]
    if doc.get("targets"):
        out["targets"] = doc["targets"]
    if doc.get("parameters"):
        out["parameters"] = doc["parameters"]
    out["tasks"] = tasks
    if doc.get("handlers"):
        out["handlers"] = [_step_to_task(h) for h in doc["handlers"]]
    if is_role:
        checks = (doc.get("monitoring") or {}).get("checks") or []
        if checks:
            out["monitoring"] = {"checks": checks}
        routes = (doc.get("notifications") or {}).get("routes") or []
        if routes:
            out["notifications"] = {"routes": routes}
    return yaml.safe_dump(out, sort_keys=False, default_flow_style=False, allow_unicode=True)
