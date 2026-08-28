#!/usr/bin/env python3
"""Generate the HTTP API reference — as prose — from the running server's own OpenAPI document.

WHY PROSE AND NOT JSON. This page exists to be read, and one of its readers is a language model. An earlier
version of this repository shipped the module reference twice: once as markdown for people and once as JSON
"for machines". That was a misunderstanding of the machine reader. A model does not need a schema dump — it
needs sentences that say what an endpoint is FOR, what it refuses, and which of two similar endpoints is the
right one. `{"type":"string"}` answers none of those questions, and the JSON copy could only ever repeat what
the markdown already said, less readably, with a second file to keep in step.

WHY GENERATED. FastAPI already holds the authoritative answer: every route, its parameters, its request body
and its docstring. A hand-written list of 481 operations would be wrong within a day. So this reads
`/openapi.json` from a RUNNING instance — not the source — because a route that exists only in a file the
router never included does not exist for a caller, and the same measurement caught exactly that twice in this
repository's history.

WHAT IT CANNOT DO, said on the page rather than papered over: an endpoint whose handler has no docstring gets
its summary (FastAPI derives that from the function name) and nothing more. Those are listed as such, so the
gap is visible and closeable instead of silently reading as "nothing more to know".

    ./generate-api-reference.py --bossman http://localhost:8123 --user admin --password …
"""

from __future__ import annotations

import argparse
import datetime
import json
import pathlib
import re
import sys
import textwrap
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent.parent

# What each tag IS, in one sentence — the thing an OpenAPI document cannot tell you and a reader needs first.
# A tag missing from here still appears on the page (with its endpoints and no blurb), because an omission
# would make the reference incomplete in a way nobody would notice; the page names them at the end instead.
TAG_BLURBS = {
    "auth": "Logging in. Everything else needs the bearer token this returns.",
    "agents": "The fleet: enrolled hosts, their facts, their modules, and the calls that reach into one host.",
    "enroll": "How a host joins the fleet — the token it presents and the certificate it gets back.",
    "monitoring": "Check results as service states, with their history and their thresholds.",
    "checks": "The check catalogue: what can be measured, and which hosts a check is assigned to.",
    "management": "Day-to-day operations on one host — services, packages, users, files, processes.",
    "resources": "Declared state: what a host is supposed to look like, and the plan/apply that gets it there.",
    "ou": "Organisational units — the tree that policies, checks and configuration are inherited through.",
    "sites": "Subnet-scoped policy: a site is a set of CIDRs, and a host belongs to one by its primary address.",
    "host-groups": "Named sets of hosts, used wherever a policy or a rollout needs a target.",
    "orchestration": "Runbooks in flight: starting one, watching its steps, and the results per host.",
    "runbooks": "The runbook library — the step lists themselves, before anyone runs them.",
    "plans": "A plan is a proposed change with its diff, kept so it can be reviewed before it is applied.",
    "remediation": "Closed-loop repair: a proposal, its guardrails, its autonomy setting, and its rollback.",
    "change-proposals": "Changes waiting for a human decision, with the reasoning that produced them.",
    "images": "PXE: boot images, provisioning profiles and the hosts being installed right now.",
    "docker": "Containers and compose projects discovered on a host, and their desired state.",
    "templates": "Configuration templates — whole-file renders for configuration a codec cannot parse.",
    "config-templates": "The template catalogue itself: schemas, samples and the Jinja sources.",
    "config-fields": "One question, one answer: which fields does this configuration file have, and how is it written?",
    "config-codecs": "Which configuration files this system can parse, and with which grammar.",
    "config-directives": "Per-key knowledge for parsable configuration files: types, defaults and allowed values.",
    "config-sync": "Bringing a host's configuration back in line with what is declared for it.",
    "document": "The server-as-document view: one host as one JSON document, and its history.",
    "chat": "The natural-language interface over the fleet, and the tools it is allowed to call.",
    "knowledge": "The retrieval memory the chat and the remediation reasoning read from.",
    "chunks": "The indexed pieces of that memory.",
    "mmc": "The management console: the snap-in tree, and one snap-in's rows and actions for one host.",
    "dashboard": "The overview numbers, and the dashlets a user has arranged.",
    "search": "Fleet-wide search — the saved searches and the query language behind the Fleet Overview.",
    "graphs": "Metric series for plotting: what exists, and the points in a time range.",
    "forecast": "Where a series is heading, for capacity questions.",
    "topology": "How hosts are connected, as measured rather than as drawn.",
    "relationships": "Dependencies between objects, used to explain an outage by its cause.",
    "business-services": "Aggregation: many technical states rolled into one service that a non-operator understands.",
    "compliance": "Software compliance: which hosts hold a version they should not.",
    "security": "CVE exposure per host, and the actions taken about it.",
    "events": "The event console: raw events before they are anything else.",
    "audit": "Who did what, in this server.",
    "activity": "What happened recently, as an operator's timeline.",
    "notifications": "Channels and escalation: who is told, how, and after how long.",
    "scheduler": "Recurring work: what runs when, and whether the last run succeeded.",
    "time-periods": "Named windows — business hours, maintenance — that other rules refer to.",
    "rollouts": "Staged change across many hosts, with the gate between stages.",
    "deployments": "A rollout in progress, per host.",
    "systems": "Test systems: a clone of a production system, for rehearsing a change.",
    "clusters": "Hosts that belong together as one failure domain.",
    "vm": "Virtual machine lifecycle on a hypervisor.",
    "devices": "Things that are not hosts: switches, PDUs, anything polled off-host.",
    "processes": "What is running on a host, and its resource use.",
    "helm": "Kubernetes releases, as declared state.",
    "blueprints": "A reusable bundle of declared state that can be applied to a new host.",
    "capabilities": "What a host can provide and what it requires — the matcher behind the lego model.",
    "modules": "The Ansible-compatible module catalogue: specifications, and which are translated.",
    "translate": "Turning a catalogue specification into something an agent can execute.",
    "package-catalog": "Every package this system knows configuration for.",
    "package-qualify": "The batch that classifies a package's configuration files.",
    "package-wizard": "Guided setup for one package's configuration.",
    "users": "Accounts in this server, and their roles.",
    "admin": "Server-side maintenance that is not about any one host.",
    "system-settings": "This server's own settings.",
    "agent-release": "Agent packages this server offers for installation and upgrade.",
    "value-maps": "Turning a raw number into the word a human reads.",
    "severity-labels": "The names this installation gives to severities.",
    "vault": "Secrets by reference: a runbook names a secret, never carries it.",
    "apps": "Application definitions layered over hosts.",
    "runs": "One execution of something, whatever started it.",
    "health": "Is this server alive. No token needed.",
    "help": "The in-product help texts.",
}

# Tags whose endpoints change a host or this server. Said once per group rather than per endpoint, because a
# reader deciding WHICH endpoint to call needs the warning before the list, not 30 times inside it.
WRITE_HEAVY = {"management", "resources", "remediation", "rollouts", "images", "docker", "vm", "helm",
               "config-sync", "orchestration", "admin", "users", "vault", "blueprints", "systems"}


def api(base: str, path: str, token: str | None = None, payload: dict | None = None):
    request = urllib.request.Request(
        base.rstrip("/") + path,
        data=json.dumps(payload).encode() if payload is not None else None,
        headers={"content-type": "application/json"} | ({"authorization": f"Bearer {token}"} if token else {}),
        method="POST" if payload is not None else "GET",
    )
    # No proxy: this server is on the local network and the corporate proxy answers such calls with 403 —
    # the same defect already fixed in the agent client, the WinRM helper and the module-docs generator.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(request, timeout=180) as response:
        return json.loads(response.read())


def resolve(schema: dict, spec: dict, depth: int = 0) -> dict:
    """Follow one $ref. Not recursive beyond a couple of levels: a reference page that inlines a whole object
    graph stops being readable, and the point here is the fields a caller has to supply."""
    if depth > 3 or not isinstance(schema, dict):
        return schema if isinstance(schema, dict) else {}
    ref = schema.get("$ref")
    if ref and ref.startswith("#/components/schemas/"):
        name = ref.rsplit("/", 1)[1]
        return resolve((spec.get("components", {}).get("schemas") or {}).get(name, {}), spec, depth + 1)
    for key in ("anyOf", "oneOf", "allOf"):
        options = [o for o in (schema.get(key) or []) if (o or {}).get("type") != "null"]
        if options:
            merged = resolve(options[0], spec, depth + 1)
            return merged | {k: v for k, v in schema.items() if k not in (key,)} if merged else schema
    return schema


def type_word(schema: dict, spec: dict) -> str:
    """The type as a reader would say it out loud, not as JSON Schema spells it."""
    schema = resolve(schema or {}, spec)
    if schema.get("enum"):
        values = [str(v) for v in schema["enum"] if v is not None]
        return "one of " + ", ".join(f"`{v}`" for v in values) if values else "string"
    kind = schema.get("type")
    if kind == "array":
        return f"list of {type_word(schema.get('items') or {}, spec)}"
    if kind == "integer":
        return "whole number"
    if kind == "number":
        return "number"
    if kind == "boolean":
        return "true or false"
    if kind == "object":
        return "object"
    return kind or "string"


def sentence(text: str | None) -> str:
    """A docstring as one flowing paragraph: newlines and indentation are how the source was formatted, not
    part of what it says."""
    if not text:
        return ""
    text = textwrap.dedent(text).strip()
    paragraphs = [re.sub(r"\s+", " ", p).strip() for p in re.split(r"\n\s*\n", text)]
    return "\n\n".join(p for p in paragraphs if p)


def anchor(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def describe_operation(method: str, path: str, op: dict, spec: dict) -> list[str]:
    lines = [f"#### `{method} {path}`", ""]
    summary = (op.get("summary") or "").strip()
    body = sentence(op.get("description"))
    if body:
        # FastAPI uses the docstring's first line as the description AND derives the summary from the
        # function name, so printing both would say the same thing twice in different words.
        lines += [body, ""]
    elif summary:
        lines += [f"{summary}. _(No further description in the source — the handler has no docstring, so this "
                  f"is all the server itself says about it.)_", ""]
    else:
        lines += ["_Undocumented in the source._", ""]

    parameters = op.get("parameters") or []
    path_params = [p for p in parameters if p.get("in") == "path"]
    query_params = [p for p in parameters if p.get("in") == "query"]
    for group, label in ((path_params, "In the path"), (query_params, "Query parameters")):
        if not group:
            continue
        lines.append(f"{label}:")
        lines.append("")
        for p in group:
            schema = resolve(p.get("schema") or {}, spec)
            bits = [type_word(schema, spec)]
            bits.append("required" if p.get("required") else "optional")
            if schema.get("default") is not None:
                bits.append(f"default `{json.dumps(schema['default'])}`")
            note = sentence(p.get("description")) or sentence(schema.get("description"))
            lines.append(f"- `{p['name']}` ({', '.join(bits)}){' — ' + note if note else ''}")
        lines.append("")

    request_body = ((op.get("requestBody") or {}).get("content") or {}).get("application/json")
    if request_body:
        schema = resolve(request_body.get("schema") or {}, spec)
        properties = schema.get("properties") or {}
        required = set(schema.get("required") or [])
        if properties:
            lines += ["The JSON body carries:", ""]
            for name, prop in sorted(properties.items(), key=lambda kv: (kv[0] not in required, kv[0])):
                prop = resolve(prop, spec)
                bits = [type_word(prop, spec), "required" if name in required else "optional"]
                if prop.get("default") is not None:
                    bits.append(f"default `{json.dumps(prop['default'])}`")
                # A pydantic field with no description still HAS a title, because FastAPI prettifies the
                # field name into one ("add_tags" → "Add Tags"). Printing that as an explanation says the
                # field name twice and reads as documentation where there is none.
                title = (prop.get("title") or "").strip()
                if title.lower().replace(" ", "_") == name.lower():
                    title = ""
                note = sentence(prop.get("description")) or sentence(title)
                lines.append(f"- `{name}` ({', '.join(bits)}){' — ' + note if note else ''}")
            lines.append("")
        elif schema.get("type") == "object" or schema.get("additionalProperties"):
            lines += ["Takes a free-form JSON object as its body.", ""]

    return lines


def build(spec: dict, counts: dict) -> str:
    operations: dict[str, list[tuple[str, str, dict]]] = {}
    for path, methods in sorted(spec.get("paths", {}).items()):
        for method, op in methods.items():
            if method.lower() not in ("get", "post", "put", "patch", "delete"):
                continue
            for tag in (op.get("tags") or ["(untagged)"]):
                operations.setdefault(tag, []).append((method.upper(), path, op))

    total = sum(len(v) for v in operations.values())
    undocumented = sum(1 for v in operations.values() for _, _, op in v if not op.get("description"))
    unblurbed = sorted(t for t in operations if t not in TAG_BLURBS)
    now = datetime.date.today().isoformat()

    lines = [
        "# The HTTP API, endpoint by endpoint",
        "",
        "> **GENERATED** by `scripts/generate-api-reference.py` from a *running* server's `/openapi.json`, on",
        f"> {now}. Do not edit by hand — the next run overwrites it. It is generated from the running server",
        "> rather than from the source because a route that the router never included does not exist for a",
        "> caller, and measuring instead of reading the source caught exactly that twice here.",
        "",
        "## How to read this, and how to use it",
        "",
        "This is the complete callable surface of Bossman: "
        f"**{total} operations** across **{len(operations)} groups**. It is written in prose on purpose. If you",
        "are a language model working in this repository, this page plus [the developer guide](developing.md)",
        "should be enough to call anything here correctly without reading the server's source first.",
        "",
        "Three things hold everywhere and are not repeated per endpoint:",
        "",
        "1. **Everything except `/healthz` and `/api/v1/auth/login` needs a bearer token.** `POST",
        "   /api/v1/auth/login` with `{\"username\", \"password\"}` returns `access_token`; send it as",
        "   `Authorization: Bearer <token>`.",
        "2. **A host is addressed by its agent id**, not by its name — names are not unique across the",
        "   lifetime of a fleet, and an endpoint that took a name would silently act on the wrong host after a",
        "   rebuild. `GET /api/v1/agents` maps names to ids.",
        "3. **A refusal says why.** A 4xx from this server carries a `detail` that names the reason; when an",
        "   *agent* refuses something, the call still succeeds and the refusal is in the result body (outcome",
        "   `refused`). Those two are different events and must not be collapsed: the first means the request",
        "   was wrong, the second means the host said no.",
        "",
        f"Of the {total} operations, **{total - undocumented} carry a description** written in the handler",
        f"itself; **{undocumented} carry only a summary** and are marked as such below rather than being",
        "quietly padded with invented prose. That number is the honest measure of how documented this API is.",
        "",
        "### Related pages",
        "",
        "- **[Developer guide](developing.md)** — the invariants, the contracts, and how to add a module, a",
        "  check or an endpoint without breaking them. Read that first; this page is the lookup table.",
        "- **[Windows modules](modules-windows.md)** and **[Linux modules](modules-linux.md)** — what the",
        "  *agents* expose. Bossman's endpoints are how you reach them.",
        "- **[Writing a check](checks-authoring.md)** — the Starlark contract, with a worked example.",
        "",
        "## The groups",
        "",
        "| Group | Endpoints | What it is |",
        "|---|---|---|",
    ]
    for tag in sorted(operations, key=lambda t: (-len(operations[t]), t)):
        blurb = TAG_BLURBS.get(tag, "_Not yet described — see the endpoints._")
        writes = " **Changes things.**" if tag in WRITE_HEAVY else ""
        lines.append(f"| [{tag}](#{anchor(tag)}) | {len(operations[tag])} | {blurb}{writes} |")
    lines.append("")

    if unblurbed:
        lines += [
            "The groups without a one-line description above are "
            + ", ".join(f"`{t}`" for t in unblurbed)
            + " — they are listed rather than hidden, so the gap is visible and closeable in",
            "`scripts/generate-api-reference.py` (`TAG_BLURBS`).",
            "",
        ]

    lines += ["---", ""]

    for tag in sorted(operations, key=lambda t: (-len(operations[t]), t)):
        lines += [f"## {tag}", ""]
        if tag in TAG_BLURBS:
            lines += [TAG_BLURBS[tag], ""]
        if tag in WRITE_HEAVY:
            lines += ["**These endpoints change a host or this server.** Where a module or a resource is",
                      "involved, `dry_run: true` returns the plan instead of applying it — use it first.", ""]
        for method, path, op in sorted(operations[tag], key=lambda t: (t[1], t[0])):
            lines += describe_operation(method, path, op, spec)
        lines += ["---", ""]

    lines += [
        "## What this page does not cover",
        "",
        "- **The agents' own HTTP API.** Each agent serves `/healthz`, `/api/v1/tools`, `/api/v1/audit` and",
        "  the module invocation endpoint on its own port (8051 for the Go agent, 8451 for the Windows one),",
        "  behind mTLS. You normally reach it *through* Bossman, and the module pages describe what it offers.",
        "- **The MCP tool surface.** The same actions are exposed to models as MCP tools; the developer guide",
        "  says which ones and how they map onto these endpoints.",
        "- **WebSocket endpoints**, which do not appear in an OpenAPI document. The web shell and the live log",
        "  tail use them.",
        "",
    ]
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bossman", default="http://localhost:8123")
    parser.add_argument("--user", default="admin")
    parser.add_argument("--password", default="admin123")
    args = parser.parse_args()

    spec = api(args.bossman, "/openapi.json")
    if not spec.get("paths"):
        print("the running server returned an OpenAPI document with no paths — refusing to write an empty "
              "reference over a good one", file=sys.stderr)
        return 2
    target = HERE / "docs" / "api-reference.md"
    target.write_text(build(spec, {}))
    operations = sum(1 for methods in spec["paths"].values() for m in methods
                     if m.lower() in ("get", "post", "put", "patch", "delete"))
    print(f"{target.relative_to(HERE)}: {operations} operations from {args.bossman}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
