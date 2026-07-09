"""Deterministic Salt (.sls) → canonical plan parser (docs/zielbestimmung.md
roadmap: Salt first, YAML-near). A Salt state file is YAML: a mapping of
state-IDs to `<module>.<function>: [args]` blocks. Each state becomes one
canonical plan step (`ansible.builtin.<module>: {...}`), feeding the SAME
plan store as NestedText/YAML/JSON — prefix "salt".

Deterministic and lossless in intent: every state function is either mapped
explicitly or raises PlanError naming the unsupported state (nothing is
silently dropped). Salt requisites (require/watch/…) express ordering, which
the plan engine already gets from step order, so they are skipped; a state's
`name` defaults to its state-ID, exactly as Salt does.
"""

from __future__ import annotations

from typing import Any, Callable

import yaml

from bossman.services.plan_loader import PlanError

# Salt requisites / meta keys that are not module arguments — skipped (order
# is carried by step sequence; conditionals are out of scope for v1).
_REQUISITES = frozenset(
    {
        "require", "watch", "onchanges", "onfail", "prereq", "use", "listen",
        "require_in", "watch_in", "onchanges_in", "onfail_in", "prereq_in", "use_in", "listen_in",
        "order", "runas", "unless", "onlyif", "check_cmd", "reload_modules",
    }
)


def _merge_args(arglist: Any) -> dict[str, Any]:
    """Salt args are a list of single-key mappings; merge them into one dict,
    dropping requisites/meta keys."""
    params: dict[str, Any] = {}
    if arglist is None:
        return params
    if not isinstance(arglist, list):
        raise PlanError(f"salt: expected a list of arguments, got {type(arglist).__name__}")
    for item in arglist:
        if not isinstance(item, dict) or len(item) != 1:
            raise PlanError(f"salt: each argument must be a single-key mapping, got {item!r}")
        (key, value), = item.items()
        if key in _REQUISITES:
            continue
        params[key] = value
    return params


# Each mapper: (salt_params, state_id) -> (ansible_module, body). `name`
# defaults to the state-ID before the mapper runs.
def _pkg(state: str) -> Callable:
    def mapper(p: dict[str, Any], _sid: str) -> tuple[str, dict[str, Any]]:
        body = {"name": p["name"], "state": state}
        return "package", body
    return mapper


def _service(state: str, enabled: bool | None) -> Callable:
    def mapper(p: dict[str, Any], _sid: str) -> tuple[str, dict[str, Any]]:
        body: dict[str, Any] = {"name": p["name"], "state": state}
        en = p.get("enable", enabled)
        if en is not None:
            body["enabled"] = en
        return "service", body
    return mapper


def _file_managed(p: dict[str, Any], _sid: str) -> tuple[str, dict[str, Any]]:
    body: dict[str, Any] = {"dest": p["name"]}
    for salt_k, ans_k in (("source", "src"), ("contents", "content"), ("mode", "mode"), ("user", "owner"), ("group", "group")):
        if salt_k in p:
            body[ans_k] = p[salt_k]
    return "copy", body


def _file_directory(p: dict[str, Any], _sid: str) -> tuple[str, dict[str, Any]]:
    body: dict[str, Any] = {"path": p["name"], "state": "directory"}
    for salt_k, ans_k in (("mode", "mode"), ("user", "owner"), ("group", "group")):
        if salt_k in p:
            body[ans_k] = p[salt_k]
    return "file", body


def _file_absent(p: dict[str, Any], _sid: str) -> tuple[str, dict[str, Any]]:
    return "file", {"path": p["name"], "state": "absent"}


def _file_symlink(p: dict[str, Any], _sid: str) -> tuple[str, dict[str, Any]]:
    return "file", {"path": p["name"], "src": p["target"], "state": "link"}


def _cmd_run(p: dict[str, Any], _sid: str) -> tuple[str, dict[str, Any]]:
    return "command", {"cmd": p.get("name")}


def _user(state: str) -> Callable:
    def mapper(p: dict[str, Any], _sid: str) -> tuple[str, dict[str, Any]]:
        body: dict[str, Any] = {"name": p["name"], "state": state}
        for salt_k, ans_k in (("uid", "uid"), ("gid", "group"), ("home", "home"), ("shell", "shell")):
            if salt_k in p:
                body[ans_k] = p[salt_k]
        return "user", body
    return mapper


def _group(state: str) -> Callable:
    def mapper(p: dict[str, Any], _sid: str) -> tuple[str, dict[str, Any]]:
        body: dict[str, Any] = {"name": p["name"], "state": state}
        if "gid" in p:
            body["gid"] = p["gid"]
        return "group", body
    return mapper


# Salt "<module>.<function>" -> mapper. Extend as coverage grows.
_MAPPING: dict[str, Callable] = {
    "pkg.installed": _pkg("present"),
    "pkg.latest": _pkg("latest"),
    "pkg.removed": _pkg("absent"),
    "pkg.purged": _pkg("absent"),
    "service.running": _service("started", True),
    "service.dead": _service("stopped", None),
    "service.enabled": _service("started", True),
    "service.disabled": _service("stopped", False),
    "file.managed": _file_managed,
    "file.directory": _file_directory,
    "file.absent": _file_absent,
    "file.symlink": _file_symlink,
    "cmd.run": _cmd_run,
    "cmd.wait": _cmd_run,
    "user.present": _user("present"),
    "user.absent": _user("absent"),
    "group.present": _group("present"),
    "group.absent": _group("absent"),
}

# Top-level .sls directives that are not states.
_DIRECTIVES = frozenset({"include", "exclude", "extend"})


def parse_salt_sls(source_text: str, name: str) -> dict[str, Any]:
    """Parse a Salt .sls into the canonical plan raw dict (with the given
    plan `name`, since .sls files carry no name themselves)."""
    try:
        data = yaml.safe_load(source_text)
    except yaml.YAMLError as exc:
        raise PlanError(f"salt: invalid YAML: {exc}") from exc
    if data is None:
        raise PlanError("salt: empty state file")
    if not isinstance(data, dict):
        raise PlanError("salt: a state file must be a mapping of state IDs")

    steps: list[dict[str, Any]] = []
    for state_id, block in data.items():
        if state_id in _DIRECTIVES:
            raise PlanError(f"salt: '{state_id}' is not supported yet (roadmap)")
        if not isinstance(block, dict):
            raise PlanError(f"salt: state {state_id!r} must be a mapping of <module>.<function>")

        for key, arglist in block.items():
            # Full form "pkg.installed:" or shorthand "pkg: [installed, {..}]".
            if "." in key:
                module_fn, args = key, arglist
            else:
                if not isinstance(arglist, list) or not arglist or not isinstance(arglist[0], str):
                    raise PlanError(f"salt: state {state_id!r}: cannot read shorthand {key!r}")
                module_fn, args = f"{key}.{arglist[0]}", arglist[1:]

            mapper = _MAPPING.get(module_fn)
            if mapper is None:
                raise PlanError(
                    f"salt: state function {module_fn!r} (in {state_id!r}) is not mapped yet — "
                    f"supported: {', '.join(sorted(_MAPPING))}"
                )
            params = _merge_args(args)
            params.setdefault("name", state_id)
            module, body = mapper(params, state_id)
            steps.append({"name": state_id, f"ansible.builtin.{module}": body})

    if not steps:
        raise PlanError("salt: no states found")
    return {"name": name, "description": f"Imported from Salt state ({name}).", "steps": steps}
