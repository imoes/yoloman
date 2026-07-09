"""yolo-man — a small ansible-playbook-style CLI over the plan engine
(Block NT-4). It reuses the exact same Plan/Chunk/PlanStep model and engine
as Bossman; the only thing new is a command-line front door and NestedText
as a first-class playbook syntax alongside YAML.

    yolo-man lint    playbook.nt
    yolo-man show    playbook.nt
    yolo-man convert playbook.yaml playbook.nt      # deterministic, either way
    yolo-man run     playbook.nt --host web01 --param msg=hi [--check]

Format is chosen by extension: .nt → NestedText, anything else → YAML. The
`run` command drives the real engine against an enrolled agent (recording a
PlanRun like the API does), so it needs Bossman's database + TLS identity
configured in the environment, exactly like the server.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from pathlib import Path
from typing import Any

import nestedtext
import yaml

from bossman.services.plan_loader import PlanError, load_plan_file


def _is_nt(path: Path) -> bool:
    return path.suffix.lower() == ".nt"


# load_plan_file already dispatches .nt/.json/YAML — kept as an alias so the
# command handlers read clearly ("load a plan in any accepted format").
load_plan_any = load_plan_file


def _bool_to_nt(value: bool) -> str:  # NestedText is all-strings; keep bools lowercase.
    return "true" if value else "false"


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
    """Read a plan file into a raw dict, by extension (.nt / .json / YAML)."""
    if _is_nt(path):
        return nestedtext.loads(path.read_text(), top="dict")
    if path.suffix.lower() == ".json":
        return json.loads(path.read_text())
    return yaml.safe_load(path.read_bytes())


def _cmd_convert(args: argparse.Namespace) -> int:
    src, dst = Path(args.src), Path(args.dst)
    try:
        raw: Any = _read_raw(src)
    except (nestedtext.NestedTextError, yaml.YAMLError, json.JSONDecodeError, OSError) as exc:
        print(f"cannot read {src}: {exc}", file=sys.stderr)
        return 1
    try:
        if _is_nt(dst):
            # NestedText leaves must be strings: stringify scalars, keeping
            # bools lowercase so they round-trip through the boolean coercion.
            out = nestedtext.dumps(raw, converters={bool: _bool_to_nt, type(None): lambda _n: ""}, default=str)
        elif dst.suffix.lower() == ".json":
            out = json.dumps(raw, indent=2)
        else:
            out = yaml.safe_dump(raw, sort_keys=False, default_flow_style=False)
    except (nestedtext.NestedTextError, yaml.YAMLError, TypeError) as exc:
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


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="yolo-man", description="NestedText/YAML playbook tool over the plan engine")
    sub = parser.add_subparsers(dest="command", required=True)

    p_lint = sub.add_parser("lint", help="parse and validate a playbook")
    p_lint.add_argument("file")
    p_lint.set_defaults(func=_cmd_lint)

    p_show = sub.add_parser("show", help="print a playbook's resolved structure")
    p_show.add_argument("file")
    p_show.set_defaults(func=_cmd_show)

    p_conv = sub.add_parser("convert", help="convert a playbook between YAML and NestedText")
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

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
