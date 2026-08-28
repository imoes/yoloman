#!/usr/bin/env python3
"""Generate the module reference pages — one per platform — from what the agents actually expose.

WHY GENERATED AND NOT WRITTEN. A hand-written module list is wrong the day after it is written: this fleet
gained eleven Windows modules in one week, and every one of them would have had to be remembered here. The
agents already publish the authoritative answer — `GET /api/v1/tools` returns each module's name, its
description, whether it writes, and its full input schema — so the page is a rendering of the fleet's own
answer rather than a second description of it that can disagree.

    ./generate-module-docs.py --bossman http://localhost:8123 --user admin --password …

Writes docs/modules-windows.md and docs/modules-linux.md, and prints what it found. It asks ONE agent per
platform (the first enrolled host of each family that answers), because the module set is a property of the
AGENT BUILD, not of the host — two hosts running the same agent expose the same modules, and a page that
merged several would hide the one that is behind.

WHAT IT CANNOT KNOW, and says so on the page instead of pretending: the Ansible-compatible module CATALOG
(2128 entries, 693 translated) is a Bossman-side library of specs, not modules an agent exposes today. The
two are different things — an agent's `GET /api/v1/tools` is what a runbook may call right now — and the page
links them rather than adding them up into one impressive number that answers nothing.
"""

from __future__ import annotations

import argparse
import datetime
import json
import pathlib
import sys
import urllib.error
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent.parent


def api(base: str, path: str, token: str | None = None, payload: dict | None = None) -> dict | list:
    request = urllib.request.Request(
        base.rstrip("/") + path,
        data=json.dumps(payload).encode() if payload is not None else None,
        headers={"content-type": "application/json"}
        | ({"authorization": f"Bearer {token}"} if token else {}),
        method="POST" if payload is not None else "GET",
    )
    # No proxy, ever: Bossman is on this network and the corporate proxy answers intra-fleet calls with 403 —
    # the same defect this project already fixed in the agent client and in the WinRM helper.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(request, timeout=120) as response:
        return json.loads(response.read())


def pick_agents(base: str, token: str) -> dict[str, dict]:
    """One agent per OS family: the module set belongs to the agent build, not to the host."""
    agents = api(base, "/api/v1/agents", token)
    chosen: dict[str, dict] = {}
    for agent in agents:  # type: ignore[union-attr]
        if agent.get("enrollment_state") != "enrolled" or not agent.get("address"):
            continue
        family = ((agent.get("facts") or {}).get("os_family") or "").lower()
        family = family if family in ("windows",) else "linux"
        chosen.setdefault(family, agent)
    return chosen


def parameter_table(schema: dict) -> list[str]:
    """The module's parameters as the module itself declares them. An enum becomes the list of values, because
    "one of started, stopped, restarted" is the answer to the question the reader has."""
    properties = (schema or {}).get("properties") or {}
    if not properties:
        return ["_Takes no parameters._", ""]
    required = set((schema or {}).get("required") or [])
    lines = ["| Parameter | Type | Required | What it means |", "|---|---|---|---|"]
    for name, spec in sorted(properties.items(), key=lambda kv: (kv[0] not in required, kv[0])):
        kind = spec.get("type", "")
        if spec.get("enum"):
            kind = "one of " + ", ".join(f"`{v}`" for v in spec["enum"])
        elif kind == "array":
            kind = f"array of {(spec.get('items') or {}).get('type', 'string')}"
        description = (spec.get("description") or "").replace("\n", " ").replace("|", "\\|")
        lines.append(f"| `{name}` | {kind} | {'yes' if name in required else '—'} | {description} |")
    lines.append("")
    return lines


def page(platform: str, agent: dict, tools: list[dict], catalog: dict) -> str:
    now = datetime.date.today().isoformat()
    writes = [t for t in tools if t.get("writes")]
    reads = [t for t in tools if not t.get("writes")]
    unsupported = [t for t in tools if t.get("supported") is False]

    other = "Linux" if platform == "Windows" else "Windows"
    other_page = "modules-linux.md" if platform == "Windows" else "modules-windows.md"

    lines = [
        f"# {platform} modules — the Ansible-shaped action plane",
        "",
        "> **GENERATED** by `scripts/generate-module-docs.py` from what the agent itself publishes",
        f"> (`GET /api/v1/tools` on `{agent.get('name')}`), on {now}. Do not edit by hand: the next run",
        "> overwrites it, and the point of generating it is that this page cannot disagree with the agents.",
        "",
        "## What this is",
        "",
        "Every module this platform's agent exposes **right now**, with the parameters the module itself",
        "declares. A module is the unit a runbook step, a console action and an MCP tool call all use — the same",
        "name, the same parameters, on every host of this platform.",
        "",
        f"**{len(tools)} modules**: {len(writes)} that change the host, {len(reads)} that only read it."
        + (f" {len(unsupported)} are listed but not usable on this host (see below)." if unsupported else ""),
        "",
        "Two rules hold for all of them, and they are why the tables below are worth reading rather than",
        "skimming:",
        "",
        "1. **Every write module is idempotent and previewable.** It reads the host first, compares, and reports",
        "   `changed: false` when nothing had to happen. `dry_run: true` returns the plan instead of applying it.",
        "2. **The target's own words are passed through, not mapped.** Where Windows says `InstallState:",
        "   Removed` or `RestartNeeded: Maybe`, that is what the module reports — a boolean would have to invent",
        "   one of two lies.",
        "",
        f"The other platform's page: [{other} modules]({other_page}).",
        "",
        "## The module catalogue is a different thing",
        "",
        f"Bossman also holds an Ansible-compatible module **catalogue** — {catalog.get('total', '?')} specs,",
        f"{catalog.get('translated', '?')} of them translated into executable form (`GET /api/v1/modules`).",
        "That is a library of specifications; this page is what an agent will execute if you call it today. The",
        "two are deliberately not added together: one impressive number would answer neither question.",
        "",
    ]

    if unsupported:
        lines += [
            "## Listed but not usable here",
            "",
            "A module the agent knows about and cannot run **stays in the listing with its reason** — an",
            "omission would leave a caller unable to tell \"this system cannot do it\" from \"this host cannot\".",
            "",
            "| Module | Why not |",
            "|---|---|",
        ]
        for tool in sorted(unsupported, key=lambda t: t["name"]):
            reason = (tool.get("unsupported_reason") or "").replace("\n", " ").replace("|", "\\|")
            lines.append(f"| `{tool['name']}` | {reason} |")
        lines.append("")

    for section, group in (("Modules that change the host", writes), ("Read-only modules", reads)):
        usable = [t for t in group if t.get("supported") is not False]
        if not usable:
            continue
        lines += [f"## {section}", ""]
        for tool in sorted(usable, key=lambda t: t["name"]):
            description = (tool.get("description") or "").strip()
            lines += [
                f"### `{tool['name']}`",
                "",
                description if description else "_No description._",
                "",
            ]
            lines += parameter_table(tool.get("input_schema") or {})

    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bossman", default="http://localhost:8123")
    parser.add_argument("--user", default="admin")
    parser.add_argument("--password", default="admin123")
    args = parser.parse_args()

    token = api(args.bossman, "/api/v1/auth/login",
                payload={"username": args.user, "password": args.password})["access_token"]  # type: ignore[index]
    catalog = api(args.bossman, "/api/v1/modules", token)
    agents = pick_agents(args.bossman, token)
    if not agents:
        print("no enrolled agent with an address — nothing to generate from", file=sys.stderr)
        return 2

    written = []
    for family, platform in (("windows", "Windows"), ("linux", "Linux")):
        agent = agents.get(family)
        if agent is None:
            print(f"no {family} agent reachable — {platform} page NOT regenerated (the old one is left in "
                  f"place rather than replaced with an empty list)", file=sys.stderr)
            continue
        try:
            tools = api(args.bossman, f"/api/v1/agents/{agent['id']}/tools", token)["tools"]  # type: ignore[index]
        except urllib.error.HTTPError as exc:
            print(f"{agent['name']} could not be asked for its tools ({exc}) — {platform} page NOT "
                  f"regenerated", file=sys.stderr)
            continue
        target = HERE / "docs" / f"modules-{family}.md"
        target.write_text(page(platform, agent, tools, catalog))  # type: ignore[arg-type]
        written.append(f"{target.relative_to(HERE)}: {len(tools)} modules from {agent['name']}")

    print("\n".join(written) if written else "nothing written")
    return 0 if written else 1


if __name__ == "__main__":
    raise SystemExit(main())
