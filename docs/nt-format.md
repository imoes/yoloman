# The yolo-man NestedText format: runbooks & roles

> **Status: agreed design spec (not yet implemented).** This captures the
> decisions from the NT-format discussion; it is the spec the parser/engine
> will be built against. See [`nestedtext-playbooks.md`](nestedtext-playbooks.md)
> for the simpler agent-side NT playbook CLI that exists today.

## Why this format exists

Ansible is the model — but Ansible mixes *data* and *logic* in one YAML file
(Jinja templating, `when:`/`loop:` expressions inline), and YAML's implicit
typing + quoting rules are a constant footgun. yolo-man splits the two:

- **Data is NestedText** — everything is a string / list / dict, no implicit
  typing (no Norway problem), no quoting/escaping. A password, a regex, a SQL
  statement, a version like `3.10` — all verbatim text.
- **Logic is Starlark** — sandboxed, deterministic, `check_mode`-previewable.
  Anything a step can't express declaratively drops into a `starlark` step.

## One format, two uses (unified — decision 3)

The same grammar authors both:

- **Runbook** — an ordered procedure you run ad-hoc or on a schedule
  (`yolo-man run web-baseline.nt`). Replaces the old `plans_dir/*.yaml`.
- **Role** — a runbook plus the monitoring/alerting a *kind of host* carries;
  bound to an OU / group / host in OU / Policy, compiled into desired state.
  This is the authoring surface for the existing `OrchestrationPlan` +
  `generated_monitoring` (the compiler is unchanged).

`host_vars` / `group_vars` / `ou_vars` are NestedText too. A file is a role iff
it has a top-level `role:` key; otherwise it's a runbook.

## Step shape (explicit, not magic)

Unlike Ansible's "the module name is the key," a step names its module
explicitly — unambiguous for both a human and an LLM, and unambiguous in NT's
flat all-string grammar:

```nestedtext
steps:
  -
    name: install nginx
    module: apt
    args:
      name: nginx
      state: present
```

`name` (label), `module`, `args` (the module's params). Optional per-step keys:
`when`, `loop`, `register`, `ignore_errors`.

> **NestedText has no inline collections.** Unlike YAML, there is no
> `{a: b, c: d}` or `[x, y]` flow syntax — a value after `key:` on the same
> line is *always a string*. Dicts and lists are written multi-line + indented
> (`args:` then indented `name: …`, lists with `-`). This is exactly why the
> Norway/typing problems can't occur, but it's the one thing to remember when
> coming from YAML.

There is **no `become`/privilege step** — the agent runs as root, so
escalation is never needed (and never a footgun).

### `run:` — the shell shorthand (an explicit, gated escape hatch)

For a plain shell one-liner, `run:` is sugar for `module: shell`:

```nestedtext
steps:
  -
    name: rebuild the font cache
    run: fc-cache -f && echo done
```

Two escape hatches, deliberately distinct:

- **`module: starlark`** — the *sandboxed* escape: deterministic, `check_mode`
  aware, no ambient authority. **Prefer this** for logic.
- **`run:` / `module: shell`** — *real* `/bin/sh -c` (pipes, globs, redirects).
  The non-sandboxed "I know what I'm doing" path: only available when
  `write: true` and subject to the command whitelist + audit log, exactly like
  the existing `shell` module. Not a general logic layer — use it for genuine
  shell, and reach for `starlark` otherwise.

## Control flow — Ansible parity (decision 1)

Full `when` / `loop` / `register`, plus an escape hatch to Starlark for
anything more.

```nestedtext
steps:
  -
    name: gather service facts
    module: service_facts
    register: svc

  -
    name: add the app users
    module: user
    loop:
      - alice
      - bob
      - carol
    args:
      name: ${item}          # loop binds ${item} (and ${loop.index})
      state: present
    when: ${enable_users} == true

  -
    name: reload nginx only if the config changed
    module: service
    args:
      name: nginx
      state: reloaded
    when: dropped_config.changed        # a prior step's registered result

  -
    name: anything complex lives here, not in the data
    module: starlark
    code:
      > def main(ctx, params):
      >     units = ctx.run(["systemctl","list-units","--type=service"]).stdout
      >     bad = [l for l in units.split("\n") if "failed" in l]
      >     return {"changed": False, "msg": "%d failed units" % len(bad),
      >             "data": {"failed": bad}}
```

- `when:` — a boolean expression. Operands: registered results
  (`name.changed`, `name.ok`, `name.data.<key>`) and variables (`${x}`), with
  `==`/`!=`/`<`/`>`/`and`/`or`/`not`. Evaluated by a small, sandboxed expression
  evaluator (NOT arbitrary Python) — or, when it gets hairy, move the decision
  into a `starlark` step and gate on its registered result.
- `loop:` — a list (literal or `${a_list_var}`); binds `${item}` +
  `${loop.index}` per iteration.
- `register:` — captures the step's result (`{changed, msg, data}`) under a
  name for later `when:`/`${...}`.

## Variables — bash- and brace-flexible (decision 2)

Substitution is textual and happens before the module runs. **Any of these
bracket styles resolve the same variable — use whichever you like:**

```
$var        ${var}        {{ var }}        {{var}}
```

(`$var` / `${var}` bash-style; `{{ var }}` Ansible-style. All equivalent.)
`${item}` / `{{ item }}` inside a `loop`. Undefined variable → a clear error
at lint time, never a silent empty string.

**Bash-style modifiers** (the genuinely useful subset — text templating only,
no command substitution, no arithmetic):

```
${var:-default}   use `default` if var is unset/empty
${var:?message}   fail with `message` if var is unset/empty (required var)
```

We deliberately do NOT take bash's `$(command)`, `$((math))`, or `${var//x/y}`
— those are *logic*, and logic belongs in a `starlark` step, not in the data.
So the rule of thumb: **bash syntax for referencing and defaulting values;
Starlark (or `run:`) for computing them.**

**Magic variables (Ansible-style facts).** Before a runbook runs, the agent's
own facts are gathered (the read-only `setup` module) and made available as
variables — no need to declare them:

```
${inventory_hostname}          the host's name
${ansible_hostname}            ${ansible_distribution}   ${ansible_kernel}
${ansible_architecture}        ${ansible_memtotal_mb}    ${ansible_processor_vcpus}
${ansible_board_vendor}        ${ansible_board_name}     ${ansible_product_serial}
${ansible_system_vendor}       ${ansible_bios_vendor}    ${ansible_chassis_vendor}
```

So a runbook can branch on hardware — e.g. `when: ansible_board_vendor ==
"Supermicro"` or `${ansible_distribution}`. Everything the agent collects is
reachable; explicit variables (below) override a fact of the same name.

**Precedence (GPO, reusing the check-assignment resolver):**

```
global  <  group_vars  <  ou_vars (root→leaf)  <  host_vars  <  role parameters  <  loop item
```

Same weakest→strongest merge as check thresholds — set a default on an OU, let
a host override it.

## Role bundling — "what is orchestrated is monitored"

```nestedtext
role: mysql_server
description: A MySQL database server.
parameters:
  bind_address: 127.0.0.1
  mysql_port: 3306
steps:
  -
    name: install mysql-server
    module: apt
    args:
      name: mysql-server
      state: present
  -
    name: ensure running
    module: service
    args:
      name: mysql
      state: started
      enabled: true
monitoring:
  checks:
    - mysql
    - disk
    - cpu_loads
notifications:
  routes:
    - dba-oncall
```

Binding this role to OU **Databases** → every host there installs MySQL, gets
the `mysql`/`disk`/`cpu_loads` checks (assigned via the check layer, with
discovery/provisioning where needed), and routes alerts to `dba-oncall`. The
`monitoring`/`notifications` blocks feed the existing compiler's
`generated_monitoring`.

## Run flow

```bash
yolo-man lint   web-baseline.nt        # parse + expression/var check, no host
yolo-man run    web-baseline.nt --check  # dry run: every step in check_mode
yolo-man run    web-baseline.nt          # apply
```

A role isn't "run" directly — it's bound in OU / Policy and the reconciler
pushes the compiled desired state.

## Implementation plan (next build block)

1. **Parser** (`services/nt_runbook.py`) — NestedText → a `Runbook`/`Role`
   model (steps, when/loop/register, monitoring/notifications). All values are
   strings; booleans coerced where a step key needs one (`when` result, `become`).
2. **Variable substitution** — one resolver accepting `$v` / `${v}` / `{{ v }}`,
   fed by the GPO-merged var scopes (extend the check-assignment resolver to
   vars). Undefined → lint error.
3. **Expression evaluator** — a tiny safe evaluator for `when:`
   (comparisons + and/or/not over registered results + vars); no eval().
4. **Engine** — orders steps, expands `loop`, evaluates `when`, runs each
   `module` via the agent (native or Starlark), threads `register` results,
   honours `--check`.
5. **Role → OrchestrationPlan** — a role NT compiles into a plan version
   (steps) + `generated_monitoring` (checks) + notifications, stored via the
   existing orchestration store; binding/compilation unchanged.
6. **Migration** — import the legacy `plans_dir/*.yaml` into the runbook model
   (or a one-shot `yolo-man convert`), then make NT the source of truth.
7. **Validator** — `starlark` steps validated by the same `starlark-check`
   gate; runbook lint checks module names, arg schemas, var references,
   `when`/`loop` shapes.
