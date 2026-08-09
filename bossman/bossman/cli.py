"""yolo-man — a small ansible-playbook-style CLI over the plan engine. It reuses the exact same
Plan/Chunk/PlanStep model and engine as Bossman; the only thing new is a command-line front door.

    yolo-man lint    playbook.yaml
    yolo-man show    playbook.yaml
    yolo-man convert playbook.yaml playbook.json    # deterministic, either way
    yolo-man run     playbook.yaml --host web01 --param msg=hi [--check]

Format is chosen by extension: .json → JSON, anything else → YAML. (A NestedText syntax used to sit beside
YAML here; it is gone — Ansible syntax is the one authoring format, so `convert` now only moves between the
two machine encodings of the same document.) The `run` command drives the real engine against an enrolled
agent (recording a PlanRun like the API does), so it needs Bossman's database + TLS identity configured in
the environment, exactly like the server.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from pathlib import Path
from typing import Any

import yaml

from bossman.services.plan_loader import PlanError, load_plan_file


# load_plan_file already dispatches .json/YAML — kept as an alias so the command handlers read clearly
# ("load a plan in any accepted format").
load_plan_any = load_plan_file


def _cmd_lint(args: argparse.Namespace) -> int:
    try:
        plan = load_plan_any(args.file)
    except (PlanError, OSError) as exc:
        print(f"INVALID: {exc}", file=sys.stderr)
        return 1
    n_steps = sum(len(c.steps) for c in plan.chunks)
    print(f"OK: {plan.name} — {len(plan.chunks)} chunk(s), {n_steps} step(s)")
    return 0


def _cmd_show(args: argparse.Namespace) -> int:
    try:
        plan = load_plan_any(args.file)
    except (PlanError, OSError) as exc:
        print(f"INVALID: {exc}", file=sys.stderr)
        return 1
    print(f"{plan.name}: {plan.description.strip()}")
    if plan.params:
        print("params:")
        for pname, spec in plan.params.items():
            req = " (required)" if spec.required else ""
            print(f"  - {pname}: {spec.type}{req}")
    for chunk in plan.chunks:
        gate = f" [os_family={chunk.os_family}]" if chunk.os_family else ""
        print(f"chunk {chunk.name}{gate}")
        for step in chunk.steps:
            target = step.module or step.kind
            loop = f" loop={step.loop!r}" if step.loop is not None else ""
            when = f" when={step.when!r}" if step.when else ""
            reg = f" register={step.register}" if step.register else ""
            print(f"  - {step.name} [{target}]{loop}{when}{reg}")
    if plan.final_handler:
        print(f"final_handler: {plan.final_handler.name} [{plan.final_handler.module or plan.final_handler.kind}]")
    return 0


def _read_raw(path: Path) -> Any:
    """Read a plan file into a raw dict, by extension (.json / YAML)."""
    if path.suffix.lower() == ".json":
        return json.loads(path.read_text())
    return yaml.safe_load(path.read_bytes())


def _cmd_convert(args: argparse.Namespace) -> int:
    src, dst = Path(args.src), Path(args.dst)
    try:
        raw: Any = _read_raw(src)
    except (yaml.YAMLError, json.JSONDecodeError, OSError) as exc:
        print(f"cannot read {src}: {exc}", file=sys.stderr)
        return 1
    try:
        if dst.suffix.lower() == ".json":
            out = json.dumps(raw, indent=2)
        else:
            out = yaml.safe_dump(raw, sort_keys=False, default_flow_style=False)
    except (yaml.YAMLError, TypeError) as exc:
        print(f"cannot convert: {exc}", file=sys.stderr)
        return 1
    dst.write_text(out if out.endswith("\n") else out + "\n")
    print(f"wrote {dst}")
    return 0


def _parse_params(pairs: list[str]) -> dict[str, str]:
    params: dict[str, str] = {}
    for pair in pairs:
        if "=" not in pair:
            raise SystemExit(f"--param must be key=value, got {pair!r}")
        key, _, value = pair.partition("=")
        params[key] = value
    return params


async def _run_plan_cli(args: argparse.Namespace) -> int:
    # Imported lazily so lint/show/convert stay usable without a DB/driver.
    from sqlalchemy import select
    from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

    from bossman.config import get_settings
    from bossman.db.models import Agent
    from bossman.services.agent_client import client_for
    from bossman.services.plan_engine import run_plan
    from bossman.services.plan_store import load_plan as store_load_plan

    # A file plan can be parsed up front; a --from-db plan is loaded inside
    # the session below (args.file is then the plan NAME).
    plan = None
    if not args.from_db:
        try:
            plan = load_plan_any(args.file)
        except (PlanError, OSError) as exc:
            print(f"INVALID: {exc}", file=sys.stderr)
            return 1

    settings = get_settings()
    engine = create_async_engine(settings.database_url)
    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    try:
        async with session_factory() as session:
            if args.from_db:
                try:
                    plan = await store_load_plan(session, args.prefix, args.file)
                except PlanError as exc:
                    print(f"no stored plan {args.prefix}/{args.file}: {exc}", file=sys.stderr)
                    return 1
            agent = await session.scalar(select(Agent).where(Agent.name == args.host))
            if agent is None:
                print(f"no enrolled host named {args.host!r}", file=sys.stderr)
                return 1
            client = client_for(agent, settings)
            run = await run_plan(
                session,
                agent,
                plan,
                host_vars={},
                explicit_params=_parse_params(args.param),
                dry_run=args.check,
                client=client,
                requested_by="yolo-man-cli",
            )
            print(f"plan {plan.name} on {args.host}: {run.status}")
            return 0 if run.status == "succeeded" else 2
    finally:
        await engine.dispose()


def _cmd_run(args: argparse.Namespace) -> int:
    return asyncio.run(_run_plan_cli(args))


def _cmd_runbook_lint(args: argparse.Namespace) -> int:
    from bossman.services import nt_runbook

    try:
        doc = nt_runbook.parse_file(args.file)
    except (nt_runbook.NTRunbookError, OSError) as exc:
        line = getattr(exc, "line", None)
        print(f"INVALID: {exc}" + (f" (line {line})" if line else ""), file=sys.stderr)
        return 1
    print(f"OK: {doc.kind} {doc.name!r} — {len(doc.steps)} step(s)")
    return 0


async def _run_runbook_cli(args: argparse.Namespace) -> int:
    # Same engine + variable layering as the REST endpoint, reaching the agent
    # directly over mTLS. Needs Bossman's DB + TLS identity in the environment.
    from sqlalchemy import select
    from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

    from bossman.config import get_settings
    from bossman.db.models import Agent
    from bossman.services import nt_runbook
    from bossman.services.agent_client import client_for
    from bossman.services.runbook_exec import execute_runbook

    try:
        doc = nt_runbook.parse_file(args.file)
    except (nt_runbook.NTRunbookError, OSError) as exc:
        print(f"INVALID: {exc}", file=sys.stderr)
        return 1
    if not isinstance(doc, nt_runbook.Runbook):
        print("that is a role, not a runbook — bind it in OU / Policy instead", file=sys.stderr)
        return 1

    settings = get_settings()
    engine = create_async_engine(settings.database_url)
    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    try:
        async with session_factory() as session:
            agent = await session.scalar(select(Agent).where(Agent.name == args.host))
            if agent is None:
                print(f"no enrolled host named {args.host!r}", file=sys.stderr)
                return 1
            if not agent.address:
                print(f"host {args.host!r} has no address to reach", file=sys.stderr)
                return 1
            client = client_for(agent, settings)
            _run, rr = await execute_runbook(
                session, agent, doc, settings=settings, client=client,
                request_vars=_coerce_params(_parse_params(args.var)),
                dry_run=args.check, requested_by="yolo-man-cli",
            )
    finally:
        await engine.dispose()

    mode = "check" if args.check else "apply"
    print(f"runbook {doc.name} on {args.host} [{mode}]: "
          f"{'ok' if rr.get('ok') else ('aborted' if rr.get('aborted') else 'failed')}"
          f"{' · changed' if rr.get('changed') else ''} · {rr.get('facts_gathered', 0)} facts")
    for step in rr.get("steps", []):
        item = f" [{step['item']}]" if step.get("item") is not None else ""
        err = f" — {step['error']}" if step.get("error") else ""
        print(f"  {step['status']:8} {step.get('name') or step.get('module')}{item}{err}")
    return 0 if rr.get("ok") else 2


def _coerce_params(pairs: dict[str, str]) -> dict[str, Any]:
    """CLI --var values arrive as strings; coerce int/bool so ${port} lands
    as an int (mirrors the scope-vars editor's coercion)."""
    out: dict[str, Any] = {}
    for k, v in pairs.items():
        if v in ("true", "false"):
            out[k] = v == "true"
        elif v.lstrip("-").isdigit():
            out[k] = int(v)
        else:
            out[k] = v
    return out


def _cmd_runbook_run(args: argparse.Namespace) -> int:
    return asyncio.run(_run_runbook_cli(args))


# Map a file extension to (prefix, source_format) for `store` auto-detection.
_EXT_ORIGIN = {
    ".yaml": ("ansible", "yaml"),
    ".yml": ("ansible", "yaml"),
    ".json": ("ansible", "json"),
    ".sls": ("salt", "salt"),
    ".rb": ("chef", "chef"),
    ".pp": ("puppet", "puppet"),
}


async def _store_cli(args: argparse.Namespace) -> int:
    from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

    from bossman.config import get_settings
    from bossman.services.plan_store import store_plan

    path = Path(args.file)
    prefix_default, fmt_default = _EXT_ORIGIN.get(path.suffix.lower(), ("ansible", "yaml"))
    prefix = args.prefix or prefix_default
    source_format = args.format or fmt_default
    name = args.name or path.stem

    settings = get_settings()
    engine = create_async_engine(settings.database_url)
    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    try:
        async with session_factory() as session:
            try:
                doc = await store_plan(session, prefix, name, source_format, path.read_text(encoding="utf-8"))
            except (PlanError, OSError) as exc:
                print(f"cannot store: {exc}", file=sys.stderr)
                return 1
            await session.commit()
            print(f"stored {doc.prefix}/{doc.name}@v{doc.version} (from {source_format})")
            return 0
    finally:
        await engine.dispose()


async def _ls_cli(args: argparse.Namespace) -> int:
    from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

    from bossman.config import get_settings
    from bossman.services.plan_store import list_plans

    settings = get_settings()
    engine = create_async_engine(settings.database_url)
    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    try:
        async with session_factory() as session:
            entries = await list_plans(session, prefix=args.prefix)
            if not entries:
                print("(no stored plans)")
                return 0
            for e in sorted(entries, key=lambda x: (x["prefix"], x["name"])):
                print(f"{e['prefix']:8} {e['name']:24} v{e['version']:<3} {e['source_format']}")
            return 0
    finally:
        await engine.dispose()


def _cmd_store(args: argparse.Namespace) -> int:
    return asyncio.run(_store_cli(args))


def _cmd_ls(args: argparse.Namespace) -> int:
    return asyncio.run(_ls_cli(args))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="yolo-man", description="NestedText/YAML playbook tool over the plan engine")
    sub = parser.add_subparsers(dest="command", required=True)

    p_lint = sub.add_parser("lint", help="parse and validate a playbook")
    p_lint.add_argument("file")
    p_lint.set_defaults(func=_cmd_lint)

    p_show = sub.add_parser("show", help="print a playbook's resolved structure")
    p_show.add_argument("file")
    p_show.set_defaults(func=_cmd_show)

    p_conv = sub.add_parser("convert", help="convert a playbook between YAML and JSON")
    p_conv.add_argument("src")
    p_conv.add_argument("dst")
    p_conv.set_defaults(func=_cmd_convert)

    p_run = sub.add_parser("run", help="run a playbook against an enrolled host")
    p_run.add_argument("file", help="playbook file, or (with --from-db) the stored plan NAME")
    p_run.add_argument("--host", required=True, help="name of the enrolled agent to run against")
    p_run.add_argument("--param", action="append", default=[], metavar="KEY=VALUE", help="plan parameter (repeatable)")
    p_run.add_argument("--check", action="store_true", help="dry-run (check_mode) — no changes made")
    p_run.add_argument("--from-db", action="store_true", help="load the plan from the canonical store by name instead of a file")
    p_run.add_argument("--prefix", default="ansible", help="store prefix when --from-db (ansible|salt|puppet|chef)")
    p_run.set_defaults(func=_cmd_run)

    p_store = sub.add_parser("store", help="store a plan in the canonical DB (format auto-detected by extension)")
    p_store.add_argument("file", help="plan file (.nt/.yaml/.json/.sls/.rb/.pp)")
    p_store.add_argument("--prefix", help="origin system (default from extension: ansible|salt|puppet|chef)")
    p_store.add_argument("--name", help="plan name (default: file stem)")
    p_store.add_argument("--format", help="source format override (yaml|json|salt|chef|puppet)")
    p_store.set_defaults(func=_cmd_store)

    p_ls = sub.add_parser("ls", help="list plans in the canonical store")
    p_ls.add_argument("--prefix", help="filter by origin system (ansible|salt|puppet|chef)")
    p_ls.set_defaults(func=_cmd_ls)

    # `runbook` — the NestedText runbook format (Block G11): magic facts,
    # ${var} substitution, when/loop/register, GPO-resolved scope vars. Distinct
    # from the legacy `run` (Plan/chunk engine).
    p_rb = sub.add_parser("runbook", help="NestedText runbook (magic facts, when/loop, scope vars)")
    rb_sub = p_rb.add_subparsers(dest="runbook_command", required=True)

    p_rb_lint = rb_sub.add_parser("lint", help="parse + shape-validate a runbook or role")
    p_rb_lint.add_argument("file")
    p_rb_lint.set_defaults(func=_cmd_runbook_lint)

    p_rb_run = rb_sub.add_parser("run", help="run a runbook against an enrolled host")
    p_rb_run.add_argument("file", help="runbook .nt file")
    p_rb_run.add_argument("--host", required=True, help="name of the enrolled agent to run against")
    p_rb_run.add_argument("--var", action="append", default=[], metavar="KEY=VALUE", help="runbook variable (repeatable)")
    p_rb_run.add_argument("--check", action="store_true", help="dry-run (check_mode) — no changes made")
    p_rb_run.set_defaults(func=_cmd_runbook_run)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
