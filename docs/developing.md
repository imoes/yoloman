# Developer guide — and the guide for an AI working in this repository

This page is written for whoever is about to change this code: a person joining, or a language model given a
task in this repository. Both need the same things and in the same order — what the system *is*, where truth
lives, which contracts must not be broken, and the traps that are only visible after they have been hit.

It is prose, deliberately. A schema tells you the shape of a request; it cannot tell you that two similar
endpoints exist and which one is right, or that a boolean where the host says "maybe" is a lie. Those are the
things that go wrong, and they can only be said in sentences.

**Companion pages:** [the HTTP API endpoint by endpoint](api-reference.md) (generated from the running
server), [Windows modules](modules-windows.md) and [Linux modules](modules-linux.md) (generated from the
agents themselves), and [writing a check](checks-authoring.md).

---

## 1. What this system is, in one page

A fleet of hosts, each running an **agent**, coordinated by one server called **Bossman**, driven by an
**Angular** web UI and by **MCP tools** so a model can operate it the same way a person does.

The idea that everything else follows from: **a server is a document.** One host is one JSON document — its
measured state, its declared state, its configuration, its history — and every feature is a view of that
document or an edit to it. Monitoring reads it; runbooks edit it; the console renders one branch of it; the
chat answers questions about it.

Three planes, and it is worth knowing which one you are in:

- **The data plane** — what is true about a host right now. Facts, metrics, check results, discovered
  services, containers, disks, processes. Measured, never assumed.
- **The action plane** — modules. One module is one verb (`service`, `package`, `registry`, `user`,
  `command`), idempotent, previewable with `dry_run`. A runbook step, a console button and an MCP tool call
  all end in the same module with the same parameters.
- **The governance plane** — who may do what, what needs approval, what was done and why. The audit trail,
  the change proposals, the guardrails, the result log.

Two agents implement the same contract on different systems: a **Go** agent for Linux (and the PXE
environment) and a **C#/.NET** agent for Windows. Where a concept exists on both, the module has the *same
name* on both. Where it does not — `registry`, `windows_feature`, `iis` — it is named for what it is.

---

## 2. Where things are

| Path | What lives there |
|---|---|
| `cmd/`, `internal/` | The Go agent. `internal/modules` is the action plane, `internal/collect` the data plane, `internal/state` plan/apply, `internal/starmod` the Starlark runtime for checks, `internal/server` its HTTP API. |
| `windows-agent/` | The Windows agent: `.Core` (contracts), `.Modules` (the modules), `.Windows` (WMI, the PowerShell bridge), `.Host` (the service), `.Tests`, `packaging/` (MSI + install scripts). |
| `bossman/bossman/api/` | 75 routers — the HTTP surface. One file per subject; the file name matches the tag in [the API reference](api-reference.md). |
| `bossman/bossman/services/` | 123 modules of actual logic. The poller, the monitoring loop, the resource objects, the schema derivation, the remediation engine. **Endpoints stay thin; logic goes here.** |
| `bossman/bossman/db/` | `models.py` (SQLAlchemy models, Timescale hypertables for metrics) and the session factory. |
| `bossman/alembic/` | Migrations. **One lineage, one head** — check with `alembic heads` before adding one. |
| `bossman-ui/src/app/features/` | 43 feature folders, grouped into workspaces by the shell. Angular 20, signals, `@if`/`@for`. |
| `configs/` | The catalogues: `checks.d/` (1432 Starlark checks), `config_codecs.json` (14599 file paths), `config_directives.json` (2130), `config_templates/` (5475 dirs), `mmc_snapins.json` (19 snap-ins). |
| `bin/` | `starlark-check` — the validator to run before pushing any check. `agentic-mcpd` — a built agent. |
| `scripts/` | Batch pipelines and the documentation generators. |
| `deploy/` | The compose stack, the PXE image, the container files. |
| `docs/` | This. One design document per subject, plus the generated pages and the published site. |

**Truth lives in exactly one place per fact**, and that place is usually not the one you would guess:

- What modules exist → **the agent's** `GET /api/v1/tools`. Not a list in Bossman, not a doc page.
- What a check measures → its `.star` file and its `.yaml` sidecar next to it.
- What a configuration file's fields are → `GET /api/v1/config-fields?path=…`, which derives them from the
  codec plus the directive catalogue. Not the UI's own idea of a form.
- What a host looks like → the poller's stored facts, refreshed on a cycle, with the timestamp visible.
- What the API offers → the running server's `/openapi.json`, which is why the reference is generated from it.

---

## 3. The contracts. Break these and something lies to an operator

### 3.1 A module is idempotent and previewable

Every write module reads the host first, compares, and reports `changed: false` when nothing had to happen.
`dry_run: true` returns the plan and changes nothing. This is not politeness — the whole governance plane
(proposals, rollouts, rehearsals, closed-loop remediation) is built on being able to ask "what would this do"
and on "apply twice equals apply once".

When you add a module, its verification is three calls, in this order, against a real host: create, the same
call again (must report unchanged), remove.

### 3.2 The target's own words are passed through, never mapped

Windows reports seven install states for a feature (`Installed`, `Removed`, `Available`, …) and
`RestartNeeded: yes | no | maybe`. The module reports exactly those. A boolean would have to invent one of two
lies about `maybe`, and the operator who needs to know would have no way to find out.

The same rule made the operation log's eight outcomes distinct and non-interchangeable — `changed`,
`unchanged`, `planned`, `refused`, `error`, `timed-out`, `unknown-module`, `gap`. In particular:
**`timed-out` may have completed.** Folding it into `error` would assert something nobody measured.

### 3.3 Nothing vanishes silently

Every enumeration is exhaustive, and "was there, is gone" is a *named* state, not an absence. A discovered
service that disappears becomes `vanished`; records lost from a ring buffer before collection leave a `gap`
marker at the position they occupied; a module the agent knows but cannot run on this host stays in the
listing **with its reason**, because an omission leaves the caller unable to distinguish "this system cannot
do it" from "this host cannot do it".

If your change can make something disappear from a list, it must instead make it appear as gone.

### 3.4 A refusal names its reason, and two kinds of refusal are different things

A 4xx from Bossman means the request was wrong; its `detail` says how. An agent refusing to do something is
*not* an error — the call succeeds and the result carries outcome `refused` with the host's reason. Collapsing
those two loses the distinction between "you asked wrongly" and "the host said no", which are acted on
differently.

Related, and learned the hard way: **an HTTP 200 is not a success.** When Bossman pushes checks to an agent,
the agent validates each one and reports per-module failures *inside* a 200 response. Bossman used to read
only the status, so a check that failed validation was silently refused and the host kept running the previous
version — a service state reporting an error from source code that no longer existed. Read the body.

### 3.5 Two write paths for configuration, and the codec chooses

A configuration file this system can parse (`codec != none`, 7287 paths) is written by **merge**: parse the
file, overlay the declared keys, serialise — foreign keys survive. A file it cannot parse (`codec == none`,
7312 paths) is written by **whole-file render** from a Jinja template. These are separate modules (`config`
vs `template_render`), separate resource types, separate plan/observe paths, and they must stay separate: a
merge cannot express a file it cannot parse, and a render silently destroys anything it did not know about.

The UI must not decide which one applies. `GET /api/v1/config-fields?path=…` answers with the fields *and*
the write path.

### 3.6 Configuration is edited as values, never as text

There is no textarea for a config file. Fields come from the catalogue with types, defaults, descriptions and
allowed values; the user edits values; the host writes the file. A free-text editor would make every
validation, diff, policy inheritance and rollback impossible.

### 3.7 Policy has a precedence order and it is visible

`global < group < OU < site < host`. Any screen showing an effective value must be able to say where it came
from. A value with no reachable origin is unexplainable, and unexplainable state is how operators lose trust
in a tool.

### 3.8 Never cap an LLM's output

No `max_tokens`, no `n_predict`, anywhere — including test mocks, where the parameter should not exist. The
model bounds itself by its context; a cap produces `finish_reason=length`, and a reasoning model spends the
budget thinking and returns nothing. If output is truncated, turn *thinking* off
(`extra_body={"chat_template_kwargs": {"enable_thinking": false}}`).

### 3.9 One name, one thing

The same entity keeps its name through database, API and UI. A host is a host (its identifier is the *agent
id* everywhere); a check is a check; a module is a module. If a translation is unavoidable, it happens in one
place. Most logic bugs in this repository started as two names for one thing, which is why the
[logic audit](#8-the-logic-audit) below is part of the workflow rather than an afterthought.

---

## 4. How to add things

### A module (Go, Linux)

Write it in `internal/modules/`, implement the module interface, register it. Read → compare → act → report,
with `dry_run` honoured before anything is written. Add a unit test next to it; add the host verification
(create / again / remove) to your own checklist and actually run it against a real host.

### A module (C#, Windows)

Prefer `DeclarativeModule` in `AgenticMcp.Agent.Modules` — it carries the seven repeated steps (validate,
observe, compare, plan, apply, verify, report) so a new module supplies only the platform-specific parts. Read
through WMI where possible; use `WindowsPowerShellBridge` where WMI has no answer. Two rules with scars behind
them: **secrets go into the child process's environment, never onto its command line**, and **well-known
principals are resolved through their SID** (`WindowsPrincipals`) because "Everyone" is *Jeder* on a German
installation and a declaration written once must work on any installation language.

### A check

`configs/checks.d/<name>.star` plus `<name>.yaml`. The runtime gives you `ctx.probe(kind, params)`,
`ctx.facts()`, `ctx.run(argv)`, `ctx.file_read(path)` — **and no clock**. Return
`{changed, msg, data: {state, metrics, details}}`, where `metrics` is a *dict* of name→number and the name
carries the unit (`agent_connect_ms`). Then run `bin/starlark-check -strict <file>` — it names the exact
missing key in a second, and it is the difference between finding a mistake now and finding it as an UNKNOWN
service state later.

Two Starlark traps that pass every parser and fail at runtime on the host: there is **no implicit string
concatenation** across lines (use `+`), and `%` takes **only bare verbs** — `%.1f` raises "unknown conversion"
when the check runs, not when it is validated. Round arithmetically and use `%s`.
[The worked example](checks-authoring.md) is `configs/checks.d/yoloman_agent_selfcheck.star`, which is
commented with exactly the mistakes its author made.

### An endpoint

A router in `bossman/bossman/api/`, thin; the logic in `services/`. **Write a docstring** — it becomes the
description in [the API reference](api-reference.md), which counts how many handlers still have none and says
so on its own first page. That number is deliberately not repeated here: one fact, one place, or the two
disagree the next time someone writes a docstring.

Writing one is not a formality. The batch that closed the first 33 did it by reading each handler and
*verifying* every sentence against the code, and four of those first drafts asserted behaviour the code does
not have. Tag it with the group it belongs
to; if the group is new, add its one-line description to `TAG_BLURBS` in
`scripts/generate-api-reference.py`.

### A console snap-in

Add an entry to `configs/mmc_snapins.json`: its nodes, its columns, its actions, and the module or endpoint it
needs. Availability is computed from what the host actually offers, and an unavailable snap-in shows **why**.
Create dialogs are generated from the module's own input schema, so a form can neither offer a parameter the
module would refuse nor omit one it requires — do not hand-write a form instead.

### A UI screen

A feature folder under `bossman-ui/src/app/features/`, signals for state (`computed`, not a plain field, or
the template will not update), `@if`/`@for`. Two mechanical traps: **backticks inside a template literal**
break the build with a confusing error, and a filter bound to a plain field types but does not filter.

---

## 5. Running, testing, deploying

```bash
# The stack. This is the deploy: it rebuilds the image from the repo.
docker compose -p agentic-mcp up -d --build            # add a service name to limit it
# NEVER `docker cp` a file into a running container: it is lost on the next recreate and it hides drift.

# Bossman tests. Note BOTH details: the venv lives under bossman/, not at the repo root, and the database
# URL must be PASSED — the built-in default points at localhost:5432, which is not the stack's database.
cd bossman && env BOSSMAN_DATABASE_URL="postgresql+asyncpg://bossman:bossman@127.0.0.1:55433/bossman" \
    .venv-host/bin/python -m pytest tests -q
# Without that variable ~13 tests fail with ConnectionRefusedError. They are NOT "environmental failures":
# with it they pass, and running them has found real bugs. Use `uv run` inside the container and you break
# the host venv the batch services depend on.

go test ./...                                          # the Go agent, 152 test files (verified: all compile)
cd bossman-ui && npx ng build                          # must be green before any UI commit

bin/starlark-check -strict configs/checks.d/<name>.star # before pushing a check

# The documentation generators (against the running server):
python3 scripts/generate-api-reference.py
python3 scripts/generate-module-docs.py
python3 scripts/generate-frontend-presentation.py
```

There is **one** database — the one in the compose stack. There is no separate dev database, and the host
cannot reach it directly; migrations apply through the stack's alembic service on deploy.

---

## 6. Traps that cost real time here

Every one of these was found by running against a real host, and every one had already passed its unit tests.

- **A NUL byte in an agent reply aborts the whole poll cycle's COMMIT.** Windows registry strings carry a
  trailing terminator; Postgres cannot store U+0000. Scrub at the JSON decode boundary — otherwise one host
  silently discards its own metrics, checks, inventory and policy every 60 seconds.
- **An allowlist that stores facts deletes the facts it does not own.** Record the key set you own and touch
  only those.
- **A cascade delete meets a non-cascading foreign key** when a host has metrics older than a day, and the
  500 tells the operator nothing.
- **A check that confirms itself proves nothing.** The Group Policy conflict report compared our declared
  values against the registry area we write into and called a match "policy agrees". Ask what observation
  would show the assumption to be false; if there is none, the check is decorative.
- **The corporate proxy answers intra-fleet calls with 403.** Any tool that talks to Bossman or an agent must
  disable proxies explicitly.
- **PowerShell binds `,` looser than `+`** in an array literal, so `"A=" + $x` became two entries and produced
  a read-only agent.
- **`ToString()` on a JSON array** turns every list parameter into JSON text. Pass `JsonElement` through.
- **Windows normalises `10.32.0.0/16` to `/255.255.0.0`**, so an un-normalised comparison reports "changed"
  forever.
- **`-RepetitionInterval` without `-RepetitionDuration` repeats for one day** and then stops, quietly.
- **`gpresult /X` as LocalSystem writes no file** for the default scope; pass `/SCOPE COMPUTER` and capture
  its output.
- **An agent cannot uninstall itself through itself** — the call dies with the service. Use a second channel.
- **`wix` on Linux declares its own behaviour undefined and proves it.** The MSI is built on a Windows host.
- **Three reconciler tests cannot pass while the stack is up, and it is not their fault.** There is one
  database, and the running `bossman` container attaches a reconciler to it that `LISTEN`s on
  `bossman_outbox`. `enqueue_policy_event` emits a `pg_notify` on commit *by design*, so the live worker
  wakes instantly, takes the row `FOR UPDATE`, and the test's own `process_outbox_once` — which uses `SKIP
  LOCKED` — sees nothing. Measured: the row satisfies both predicates (`pending`, `available_at` 21 ms in
  the past) and the query returns 0 rows; `pg_stat_activity` shows the listener and a second backend `idle
  in transaction`. The concurrent compile of the same fresh agent is also why a `compiled_host_state`
  generation-1 unique violation appears in the same file. Do not "fix" these tests by weakening the
  assertions.
- **Adding a parent row and a child row in one session inserts them in the wrong order.** This codebase
  declares foreign keys **without** `relationship()` on purpose — async lazy loads raise `MissingGreenlet`,
  so ORM traversal is avoided throughout — which means SQLAlchemy's unit of work has *no dependency edge*
  between the two mappers and is free to insert the child first. So: `await session.flush()` after the
  parent, before anything references it. Measured outside pytest — an `ApiToken` and an `AccessGrant`
  pointing at it, added together with no flush, raise `ForeignKeyViolationError` every time. A client-side
  generated id makes the *value* available early and says nothing about insert order.

---

## 7. Working style expected in this repository

- **Measure before you plan.** Several plans here were overturned by counting: the "generate eight wrappers"
  milestone became a shared skeleton once the eight modules were measured (379–554 lines each, not one a thin
  shell), and a documentation batch was cancelled once the overlap was counted.
- **Test on real targets.** Real disks, real hosts, the real database — not tmpfs, not mocks standing in for
  the thing under test.
- **Commit per working block**, in English, and **never push without being asked**.
- **Every claim in a document names its evidence** — measured, verified on which host, or the number counted.
  [The changelog](https://github.com/imoes/yoloman/blob/main/CHANGELOG.md) is written this way; an entry
  without evidence is a statement of intent and does not belong there.
- **Self-documenting artifacts.** Configs, templates and code carry their comments, their defaults
  (`| default`) and their descriptions inline. A schema description belongs next to the field it describes.

---

## 8. The logic audit

Before an interface, a data model or an API is considered done, it is checked against the classical laws of
thought — not as philosophy, but because these are the error classes that cause misoperation:

1. **Identity** — one thing, one name, one place; exactly one source of truth.
2. **Non-contradiction** — never two views with conflicting state for the same object; make forbidden
   combinations impossible in the *type*, not caught later in the UI; grey out impossible actions rather than
   reporting them afterwards.
3. **Excluded middle** — every case is classified; `null`/`unknown` is a *named* state; nothing vanishes
   silently.
4. **Sufficient reason** — everything displayed is explainable: the cause reachable from the state, the reason
   given for every refusal, a chain of reasoning behind every automatic action; every number with its unit,
   period and origin.
5. **Valid inference** — no causality from adjacency, no self-confirmation, no incomplete disjunction, no term
   that means something different one layer down.
6. **Intension vs extension, and parsimony** — rule (desired) and instance (observed) visibly separated with
   the rule's origin shown; two ways to the same result is a logic error, not a matter of taste.

---

## 9. If you are a language model working here

You have three ways in, and they are the same ways a person has:

- **The MCP tools.** The whole action plane is exposed as MCP tools, including `operation_log(host, module,
  outcome, since_minutes, changed_only)` — read it after you act. It is how you find out that what you did
  actually happened, and it caught a missing module within an hour of existing.
- **The HTTP API**, described endpoint by endpoint in [api-reference.md](api-reference.md). Log in, then use
  agent ids.
- **`run-module` on a host**, for the ~700 modules the agents expose. **Use the module library rather than
  reinventing host tasks as shell commands** — a module is idempotent, previewable and logged; a shell line
  is none of those.

What is expected of you specifically:

- **Read the generated pages, not your memory of them.** They are regenerated from the running system; a
  number in this guide can be stale, and the two generators say when they ran.
- **`dry_run` first**, on anything that writes.
- **Report faithfully.** If a test fails, say so with the output; if a step was skipped, say that. This
  repository's documentation is trustworthy only because nothing in it was asserted without being run — and
  the fastest way to make it worthless is one confident sentence about something that was not measured.

---

*This project is entirely vibe coded and still in development. It is documented this thoroughly because that
is the only way anyone — human or model — can safely change something they did not write.*
