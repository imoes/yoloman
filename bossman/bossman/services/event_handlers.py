"""Running an event handler: resolve the body, pass the parameters, execute.

The trigger is not here. A check entering a hard problem state, the scope matching, the rate
limit, the autonomy gate, verify and rollback, and the audit row all live in
services/remediation.py and are unchanged — event handling is a richer ACTION on the existing
trigger, not a second machine beside it (docs/event-handling.md).

What this module owns is the step between "a rule fired" and "something ran":

  body=runbook            → execute_runbook, exactly as remediation always did
  body=script location=managed → copy the source to the host, THEN run it
  body=script location=local   → run the file the agent already has

`managed` is copied before EVERY run. Copying once would let a host keep an older body than
the one Bossman displays — two truths for one script, and the operator would be reading the
wrong one while debugging.

Parameters travel as environment variables (`BOSSMAN_<NAME>`), never on the command line: a
command line is visible in `ps` and in shell history. The agent's command module gained `env`
for exactly this.

Every run also gets the event CONTEXT, including for `local` handlers, which take no
parameters. The context is not a parameter — it is the fact that caused the run, and Bossman
knows it regardless of what the script contains.
"""

from __future__ import annotations

import re
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import Agent, EventHandler, Runbook
from bossman.services import nt_runbook
from bossman.services.runbook_exec import execute_runbook

#: Where a host keeps its handler scripts. One fixed directory, so a `local` handler is named
#: by file name rather than by a path a caller could point anywhere — an event handler is not a
#: way to run an arbitrary file on a host.
HANDLER_DIR = "/etc/agentic-mcp/event-handlers"

#: Environment names must be usable by a shell. A parameter called "max-age" would become
#: BOSSMAN_MAX_AGE rather than an unusable BOSSMAN_MAX-AGE.
_ENV_SAFE = re.compile(r"[^A-Z0-9_]")


class HandlerError(RuntimeError):
    """The handler cannot be run, with the reason in the message (the API and the audit row
    both pass it through, so it is written for a human)."""


def env_name(param: str) -> str:
    return "BOSSMAN_" + _ENV_SAFE.sub("_", param.strip().upper())


def event_context(
    *, agent: Agent, service_name: str, state: str = "", value: Any = None,
    handler_name: str = "", run_id: Any = None,
) -> dict[str, str]:
    """The facts that caused the run, as environment. Always present, also for `local`.

    Values are stringified here and never None: a script reading an unset variable cannot tell
    "no value" from "variable missing", so absent facts arrive as the empty string.
    """
    return {
        "BOSSMAN_EVENT_HOST": agent.name or "",
        "BOSSMAN_EVENT_SERVICE": service_name or "",
        "BOSSMAN_EVENT_STATE": state or "",
        "BOSSMAN_EVENT_VALUE": "" if value is None else str(value),
        "BOSSMAN_EVENT_HANDLER": handler_name or "",
        "BOSSMAN_EVENT_RUN_ID": "" if run_id is None else str(run_id),
    }


def parameter_env(handler: EventHandler, values: dict | None) -> dict[str, str]:
    """Declared parameters merged with the rule's values, as environment.

    Declared-but-unset parameters fall back to their default and then to the empty string, so
    the script sees every declared name — a missing variable and an empty one are different
    failures for a shell script, and only one of them is the caller's intent.

    Values for names the handler does not declare are DROPPED rather than passed through. The
    declaration is what a rule's form was built from; smuggling extra variables past it would
    make the handler's contract unreadable.
    """
    if handler.location == "local":
        # Not a restriction but a consequence: Bossman does not know a locally-placed script's
        # contents, so it cannot say which parameters it takes. Passing values it could not
        # describe would be guessing on the operator's behalf.
        return {}
    declared = handler.parameters or []
    given = values or {}
    out: dict[str, str] = {}
    for spec in declared:
        name = str(spec.get("name") or "").strip()
        if not name:
            continue
        raw = given.get(name, spec.get("default"))
        out[env_name(name)] = "" if raw is None else str(raw)
    return out


def missing_required(handler: EventHandler, values: dict | None) -> list[str]:
    """Required parameters with neither a value nor a default — named so a caller can be told
    what is missing instead of watching a script fail on an empty variable."""
    if handler.location == "local":
        return []
    given = values or {}
    out = []
    for spec in handler.parameters or []:
        name = str(spec.get("name") or "").strip()
        if not name or not spec.get("required"):
            continue
        if given.get(name) in (None, "") and spec.get("default") in (None, ""):
            out.append(name)
    return out


def script_path(handler: EventHandler) -> str:
    """Where the script lives on the host.

    A `managed` handler is addressed by its own name, a `local` one by the file name it was
    given — both inside HANDLER_DIR, and the base name is stripped of any path so a name like
    "../../etc/shadow" cannot escape the directory.
    """
    raw = handler.local_name if handler.location == "local" else handler.name
    base = (raw or "").replace("\\", "/").split("/")[-1].strip()
    if not base or base in (".", ".."):
        raise HandlerError(f"handler {handler.name!r} has no usable script file name")
    return f"{HANDLER_DIR}/{base}"


async def _call(client, tool: str, params: dict) -> tuple[bool, Any]:
    """Call an agent module and unwrap its `data` payload.

    The payload is returned AS IT COMES — a dict for copy/command, a LIST for find (which
    returns its matches directly). Coercing it to a dict, as the disk_ops helper does, silently
    turned find's result into {} and made every local handler look missing; checked against
    internal/modules/find.go rather than assumed.
    """
    try:
        res = await client.call_tool(tool, params)
    except Exception as exc:  # noqa: BLE001 — a transport failure is a handler failure, with the reason
        return False, {"output": str(exc)[:300]}
    if not isinstance(res, dict):
        # A non-dict envelope is a protocol surprise, not a handler result: reported as a
        # failure with what arrived, rather than treated as an empty success.
        return False, {"output": f"unexpected reply from {tool}: {type(res).__name__}"}
    return True, res.get("data")


#: The probe's marker. A value the script echoes back, so the check is a MEASUREMENT of the
#: capability rather than an inference from a version number.
_PROBE_VALUE = "1"


async def supports_env(client) -> bool:
    """Can this agent actually pass environment variables to `command`?

    This must be asked, because an agent older than the `env` parameter IGNORES it silently:
    measured against a real host running 0.57.44, the handler script ran with rc 0 and printed
    "cleanup ran for  on " — the context was simply empty. A silent wrong result is worse than a
    failure, so a script handler refuses to run rather than run blind.

    Asked by probing, not by comparing versions: `list_tools` returns {name, kind, writes} with
    no input schema, and a version→feature table would be a second source of truth that has to
    be kept in step with the agent by hand. The probe measures the property itself.

    Not cached: a false negative only costs a refusal that names its reason, while a stale
    "supported" would reintroduce exactly the silent-wrong-run this exists to prevent.
    """
    ok, data = await _call(client, "command", {
        "argv": ["/bin/sh", "-c", 'printf %s "$BOSSMAN_ENV_PROBE"'],
        "env": {"BOSSMAN_ENV_PROBE": _PROBE_VALUE},
    })
    if not ok or not isinstance(data, dict):
        return False
    return str(data.get("stdout", "")).strip() == _PROBE_VALUE


async def run_handler(
    session: AsyncSession,
    settings,
    agent: Agent,
    handler: EventHandler,
    *,
    client,
    values: dict | None = None,
    service_name: str = "",
    state: str = "",
    value: Any = None,
    run_id: Any = None,
    requested_by: str = "event-handler",
) -> tuple[bool, str]:
    """Run one handler on one host. Returns (ok, detail) — never raises for a failing script,
    because a handler that exits non-zero is a result to record, not a crash.

    `detail` is written to be read in the audit row: it names what ran and what came back.
    """
    if not handler.enabled:
        return False, f"handler {handler.name!r} is disabled"
    if not agent.address:
        return False, "host has no reachable address"

    if handler.body == "runbook":
        rb = await session.scalar(select(Runbook).where(Runbook.name == handler.runbook_name))
        doc = nt_runbook.parse_data(rb.doc, source=f"runbook {handler.runbook_name!r}") if rb else None
        if not isinstance(doc, nt_runbook.Runbook):
            return False, f"runbook {handler.runbook_name!r} missing or is a role"
        missing = missing_required(handler, values)
        if missing:
            return False, f"missing required parameter(s): {', '.join(missing)}"
        # A runbook takes its parameters as request_vars (its own contract), plus the event
        # facts under the names remediation already used, so existing runbooks keep working.
        request_vars = {
            **{str(s.get("name")): (values or {}).get(str(s.get("name")), s.get("default"))
               for s in (handler.parameters or []) if s.get("name")},
            "check_service": service_name,
            "check_host": agent.name,
        }
        try:
            _, rr = await execute_runbook(
                session, agent, doc, settings=settings, client=client,
                request_vars=request_vars, dry_run=False,
                requested_by=f"{requested_by}:{handler.name}", commit=False,
            )
        except Exception as exc:  # noqa: BLE001
            return False, f"runbook error: {str(exc)[:200]}"
        ok = rr.get("ok", True) and not rr.get("aborted")
        return ok, f"runbook {handler.runbook_name!r} " + ("succeeded" if ok else "failed")

    # ---- script ----------------------------------------------------------------
    # Every script handler receives at least the event context through the environment, so an
    # agent that cannot pass it would run the script with empty variables and report success.
    # Refused with the reason instead — see supports_env.
    if not await supports_env(client):
        return False, (
            "this host's agent cannot pass environment variables to a command, so the event "
            "context (and any parameters) would arrive empty and the script would report "
            "success while doing the wrong thing — update the agent before using a script "
            "handler here"
        )
    missing = missing_required(handler, values)
    if missing:
        return False, f"missing required parameter(s): {', '.join(missing)}"
    path = script_path(handler)

    if handler.location == "managed":
        # The directory first: `copy` writes a file but does not create parents, so on a host
        # that has never received a handler the deploy failed with "no such file or directory".
        # Found by running it against a real host — the unit tests use a fake client and could
        # not see it. 0700 because the scripts inside run as root.
        ok, data = await _call(client, "file", {"path": HANDLER_DIR, "state": "directory", "mode": "0700"})
        if not ok:
            return False, f"could not create {HANDLER_DIR}: {_msg(data)}"
        # Deployed on every run, so the host cannot hold a body older than the one Bossman
        # shows. mode 0700: it runs as root and nothing else needs to read it.
        ok, data = await _call(client, "copy", {"dest": path, "content": handler.source or "", "mode": "0700"})
        if not ok:
            return False, f"could not deploy the script to {path}: {_msg(data)}"

    env = {
        **event_context(
            agent=agent, service_name=service_name, state=state, value=value,
            handler_name=handler.name, run_id=run_id,
        ),
        **parameter_env(handler, values),
    }
    interpreter = (handler.interpreter or "").strip()
    argv = [interpreter, path] if interpreter else [path]
    ok, data = await _call(client, "command", {"argv": argv, "env": env})
    if not ok:
        return False, f"could not run {path}: {_msg(data)}"
    data = data if isinstance(data, dict) else {}

    rc = data.get("rc")
    # A non-zero exit code is data, not a transport error — the module returns it and the
    # verdict is made HERE, with the code and the first line of output in the detail so the
    # audit row says why rather than only that it failed.
    tail = (data.get("stderr") or data.get("stdout") or "").strip().splitlines()
    first = tail[0][:200] if tail else ""
    if rc == 0:
        return True, f"script {path} exited 0" + (f": {first}" if first else "")
    return False, f"script {path} exited {rc}" + (f": {first}" if first else "")


def _msg(data: Any) -> str:
    """A short human reason out of whatever a module returned."""
    if isinstance(data, dict):
        return str(data.get("output") or data.get("stderr") or data.get("msg") or "")[:200]
    return str(data or "")[:200]


async def local_availability(client, names: list[str]) -> dict[str, bool]:
    """Which of these file names exist in HANDLER_DIR on one host.

    This is the observation point a `local` handler needs: its body is not in Bossman, so
    "this handler will run" is otherwise an untested claim until the event happens — and by
    then it is too late to notice the file was never installed.

    `find` returns its matches as a LIST of {path, isdir, size} (internal/modules/find.go), and
    a missing directory is an empty result rather than an error — which is the right answer
    here: nothing installed is exactly "none of them exist".
    """
    ok, data = await _call(client, "find", {"paths": [HANDLER_DIR], "file_type": "file"})
    if not ok:
        return {n: False for n in names}
    found = set()
    for entry in data if isinstance(data, list) else []:
        path = entry.get("path") if isinstance(entry, dict) else str(entry)
        if path:
            found.add(str(path).rstrip("/").split("/")[-1])
    return {n: n in found for n in names}
