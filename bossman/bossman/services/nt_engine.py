"""Block G11 (NT format, step 4): run a NestedText runbook against a host.

Orders the steps, evaluates `when:` (sandboxed Jinja2, via when_eval), expands
`loop:`, substitutes variables (nt_vars: real Jinja2 `{{ }}` + the legacy
$v / ${v} / ${v:-default} shim) against the running context, runs each `module`
on the agent via call_tool, threads `register`ed results AND `set_fact` facts
into the shared namespace (so later steps can template on them, like Ansible),
and honours check-mode (dry-run: modules get dry_run=true and never mutate).

Pure orchestration over the AgentClient.call_tool interface, so it's unit-
tested with a fake client and needs no live host. Variable scopes are merged
GPO-style by the caller (nt_vars.merge_scopes); registered results share the
namespace with variables, exactly like Ansible.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from bossman.services.nt_runbook import Runbook, Step
from bossman.services.nt_vars import substitute
from bossman.services.when_eval import WhenError, eval_when


@dataclass
class StepResult:
    name: str
    module: str
    status: str                      # ok | changed | skipped | failed
    item: Any = None
    changed: bool | None = None
    error: str = ""
    response: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        d = {"name": self.name, "module": self.module, "status": self.status,
             "changed": self.changed, "response": self.response}
        if self.item is not None:
            d["item"] = self.item
        if self.error:
            d["error"] = self.error
        return d


@dataclass
class RunResult:
    check_mode: bool
    steps: list[StepResult] = field(default_factory=list)
    aborted: bool = False

    @property
    def changed(self) -> bool:
        return any(s.changed for s in self.steps)

    @property
    def ok(self) -> bool:
        return not any(s.status == "failed" for s in self.steps) and not self.aborted

    def to_dict(self) -> dict[str, Any]:
        return {"check_mode": self.check_mode, "ok": self.ok, "changed": self.changed,
                "aborted": self.aborted, "steps": [s.to_dict() for s in self.steps]}


def _resolve_loop(step: Step, context: dict[str, Any]) -> list[Any]:
    """[None] when no loop (single iteration); a literal list as-is; a string
    is a dotted path into the context that must resolve to a list."""
    if step.loop is None:
        return [None]
    if isinstance(step.loop, list):
        return list(step.loop)
    value: Any = context
    for part in str(step.loop).strip().lstrip("${").rstrip("}").split("."):
        if not isinstance(value, dict) or part not in value:
            raise WhenError(f"loop {step.loop!r} is not defined")
        value = value[part]
    if not isinstance(value, list):
        raise WhenError(f"loop {step.loop!r} did not resolve to a list")
    return value


def _summarize_register(results: list[StepResult], looped: bool) -> dict[str, Any]:
    """The value stored under a step's `register` name — a single result's
    response for a plain step, or a {results, changed, ok} rollup for a loop
    (so later `when:` can reference name.changed / name.results)."""
    if not looped:
        r = results[-1]
        return {**r.response, "changed": bool(r.changed), "ok": r.status != "failed"}
    return {
        "results": [r.response for r in results],
        "changed": any(bool(r.changed) for r in results),
        "ok": all(r.status != "failed" for r in results),
    }


async def _apply_config_template(
    step: Any, args: dict[str, Any], item: Any, client: Any,
    variables: dict[str, Any], templates: dict[str, str], check_mode: bool,
) -> StepResult:
    """The `config_template` step: render a named config template (e.g. apache2
    vhost) to a destination file. The template body is handed to the agent as a
    template_render config resource — the agent renders the Jinja2 with `values`
    (the runbook variables overlaid with the step's own `vars`)."""
    name = args.get("template") or args.get("name")
    dest = args.get("dest") or args.get("path")
    body = templates.get(name) if name else None
    if not name or not dest:
        return StepResult(name=step.name, module=step.module, status="failed", item=item,
                          error="config_template needs `template` (name) and `dest` (path)")
    if body is None:
        return StepResult(name=step.name, module=step.module, status="failed", item=item,
                          error=f"unknown config template {name!r}")
    values = {**variables, **(args.get("vars") or {})}
    resource = {"type": "template_render", "path": dest, "template": body, "values": values}
    try:
        resp = await client.state_apply({"resources": [resource]}, check_mode)
        changes = resp.get("changes", []) if isinstance(resp, dict) else []
        changed = any(c.get("action") not in (None, "noop") for c in changes)
        return StepResult(name=step.name, module=step.module, status=("changed" if changed else "ok"),
                          item=item, changed=changed, response=resp if isinstance(resp, dict) else {"result": resp})
    except Exception as exc:  # noqa: BLE001 — recorded, not raised
        return StepResult(name=step.name, module=step.module, status="failed", item=item, error=str(exc))


def _tag_selected(tags: list[str], only: set[str] | None, skip: set[str] | None) -> bool:
    """Ansible tag selection: `always`-tagged steps always run (unless skipped);
    a step is skipped if its tags intersect skip_tags (or `all` is skipped); with
    only_tags set, a step runs only if its tags intersect it (or `all` is asked)."""
    t = set(tags or [])
    if "always" in t and not (skip and "always" in skip):
        return True
    if skip and (t & skip or "all" in skip):
        return False
    if only:
        return bool(t & only) or "all" in only
    return True


async def run_runbook(
    runbook: Runbook,
    client: Any,
    variables: dict[str, Any] | None = None,
    *,
    check_mode: bool = False,
    templates: dict[str, str] | None = None,
    only_tags: set[str] | None = None,
    skip_tags: set[str] | None = None,
) -> RunResult:
    """Run `runbook` against `client` (an AgentClient). `variables` is the
    already-GPO-merged variable scope. Returns a RunResult recording every
    step; a failed step with ignore_errors=false aborts the rest. `only_tags`/
    `skip_tags` gate which steps run (Ansible `--tags`/`--skip-tags`)."""
    variables = dict(variables or {})
    # Shared namespace for when:/register (like Ansible): starts as the vars.
    context: dict[str, Any] = dict(variables)
    out = RunResult(check_mode=check_mode)
    # Handler names notified by a `changed` step, in first-notified order.
    notified: list[str] = []

    for step in runbook.steps:
        # tags: a step not selected this run is silently omitted (no result row,
        # like Ansible — it never appears in the play recap).
        if not _tag_selected(step.tags, only_tags, skip_tags):
            continue
        # when: — a false condition skips the whole step (never a failure).
        if step.when is not None:
            try:
                if not eval_when(step.when, context):
                    out.steps.append(StepResult(name=step.name, module=step.module, status="skipped"))
                    continue
            except WhenError as exc:
                out.steps.append(StepResult(name=step.name, module=step.module, status="failed", error=f"when: {exc}"))
                if not step.ignore_errors:
                    out.aborted = True
                    return out
                continue

        items = _resolve_loop(step, context)
        looped = step.loop is not None
        iteration_results: list[StepResult] = []

        for item in items:
            # Substitute against the running context (vars + registered results +
            # set_facts), not just the initial vars — so a later step can template
            # on an earlier step's registered result, like Ansible.
            subst = dict(context)
            if item is not None:
                subst["item"] = item
            args = substitute(step.args, subst)
            # set_fact is a controller-side op (like Ansible): fold the resolved
            # facts into the shared namespace so later when:/loop:/{{ }} see them.
            # No agent round-trip needed.
            if step.module == "set_fact":
                context.update(args)
                sr = StepResult(name=step.name, module="set_fact", status="ok",
                                item=item, changed=False, response={"ansible_facts": dict(args)})
                iteration_results.append(sr)
                out.steps.append(sr)
                continue
            # A config_template step renders a named template to a file via the
            # agent's template_render apply, instead of a generic tool call.
            if step.module == "config_template":
                sr = await _apply_config_template(step, args, item, client, variables, templates or {}, check_mode)
                iteration_results.append(sr)
                out.steps.append(sr)
                if sr.status == "failed" and not step.ignore_errors:
                    out.aborted = True
                    if step.register:
                        context[step.register] = _summarize_register(iteration_results, looped)
                    return out
                continue
            body = {**args, "dry_run": True} if check_mode else dict(args)
            try:
                resp = await client.call_tool(step.module, body)
                if not isinstance(resp, dict):
                    resp = {"result": resp}
                changed = resp.get("changed")
                failed = bool(resp.get("failed")) or "error" in resp
                status = "failed" if failed else ("changed" if changed else "ok")
                sr = StepResult(name=step.name, module=step.module, status=status,
                                item=item, changed=changed, response=resp,
                                error=str(resp.get("error", "")) if failed else "")
            except Exception as exc:  # noqa: BLE001 — a module failure is recorded, not raised
                sr = StepResult(name=step.name, module=step.module, status="failed",
                                item=item, error=str(exc))
            iteration_results.append(sr)
            out.steps.append(sr)
            if sr.status == "failed" and not step.ignore_errors:
                out.aborted = True
                if step.register:
                    context[step.register] = _summarize_register(iteration_results, looped)
                return out

        if step.register:
            context[step.register] = _summarize_register(iteration_results, looped)
        # notify: a step that changed queues its handlers (Ansible fires on change).
        if step.notify and any(r.status == "changed" for r in iteration_results):
            for n in step.notify:
                if n not in notified:
                    notified.append(n)

    # Handlers: each notified handler runs once, in definition order, after all
    # tasks (like Ansible). A play that aborted above never reaches here.
    for h in runbook.handlers:
        if h.name not in notified:
            continue
        out.steps.append(await _run_handler(h, client, context, variables, templates or {}, check_mode))

    return out


async def _run_handler(
    h: Step, client: Any, context: dict[str, Any], variables: dict[str, Any],
    templates: dict[str, str], check_mode: bool,
) -> StepResult:
    """Run a single notified handler (no loop; when/args/set_fact/config_template
    honoured, mirroring a normal step)."""
    if h.when is not None:
        try:
            if not eval_when(h.when, context):
                return StepResult(name=h.name, module=h.module, status="skipped")
        except WhenError as exc:
            return StepResult(name=h.name, module=h.module, status="failed", error=f"when: {exc}")
    args = substitute(h.args, dict(context))
    if h.module == "set_fact":
        context.update(args)
        return StepResult(name=h.name, module="set_fact", status="ok", response={"ansible_facts": dict(args)})
    if h.module == "config_template":
        return await _apply_config_template(h, args, None, client, variables, templates, check_mode)
    body = {**args, "dry_run": True} if check_mode else dict(args)
    try:
        resp = await client.call_tool(h.module, body)
        if not isinstance(resp, dict):
            resp = {"result": resp}
        changed = resp.get("changed")
        failed = bool(resp.get("failed")) or "error" in resp
        status = "failed" if failed else ("changed" if changed else "ok")
        return StepResult(name=h.name, module=h.module, status=status, changed=changed,
                          response=resp, error=str(resp.get("error", "")) if failed else "")
    except Exception as exc:  # noqa: BLE001 — recorded, not raised
        return StepResult(name=h.name, module=h.module, status="failed", error=str(exc))
