# NestedText playbooks & the `yolo-man` CLI

yolo-man is Ansible-shaped: modules follow the same **JSON-in / JSON-out**
contract Ansible uses (arguments in, a single result object out — see
`internal/modules/module.go`), and a *plan* sequences module calls across
hosts the way a playbook sequences tasks. This document describes writing
those plans (and the agent's local `tools.d` tasks) in **NestedText** instead
of YAML, and the `yolo-man` CLI that runs them.

## Why NestedText

YAML's worst papercuts are its *implicit typing*: `no` becomes `false` (the
"Norway problem"), `0755` becomes an integer, `1.10` loses its trailing zero,
and `@`, `%`, `:` force you into quoting. [NestedText](https://nestedtext.org)
removes all of it — **every leaf value is a plain string**. There is no type
inference, no quoting, and no escaping; structure comes only from indentation
and a few line prefixes.

This is a deliberate division of labour:

| Layer | Job | Technology |
|-------|-----|-----------|
| NestedText | declarative **structure** (plays, tasks, args) | all-strings data |
| Starlark | module **logic** (loops, conditionals, computed values) | sandboxed, native Go interpreter |
| JSON modules | **execution** (args in, result out) | the existing module contract |

NestedText replaces only the *surface syntax*. A NestedText plan parses to the
exact same `Plan`/`Chunk`/`PlanStep` objects as a YAML plan
(`bossman/services/nt_plan_loader.py` → `plan_loader.build_plan_from_raw`), so
the whole engine below the loader — `when` evaluation, `{{ }}` substitution,
`loop`, the module contract — is shared and unchanged.

### The one consequence: scalars are strings

Because NestedText has no types, a value like `update_cache: true` parses to
the string `"true"`. The system handles this in exactly one place, the way
Ansible does with its always-stringly Jinja output: **module arguments are
coerced at the typed module boundary** (e.g. `boolParam` in
`internal/modules/params.go` accepts `"true"`/`"false"`). The loaders coerce
only the handful of fields the *schema itself* defines as booleans (a step's
`check_mode`, a param's `required`, a module sidecar's `writes`) — they never
guess types by value, which would reintroduce the very ambiguity NestedText
removes.

## Playbook (plan) syntax

A plan has a `name`, optional `description` and `params`, and either a flat
`steps:` list or named `chunks:` (each an OS-gated group of steps). Each step
is exactly one of: an `<module>:` mapping, a `pipeline:`, or an
`upload:`. Steps may carry `when`, `register`, `loop`, `check_mode`, and
`on_failure`.

```nestedtext
name: img_demo
description:
    > Install a package and write its config, restarting only on change.
params:
    pkg:
        type: string
        required: true
    proxy_url:
        type: string
        required: false
chunks:
    -
        name: debian_install
        os_family:
            - debian
        steps:
            -
                name: install
                loop:
                    - ca-certificates
                    - curl
                apt:
                    name: {item}
                    state: present
                    update_cache: true
            -
                name: check_conf
                register: conf
                stat:
                    path: /etc/demo/demo.conf
            -
                name: write_conf
                when: not conf.data.exists
                copy:
                    dest: /etc/demo/demo.conf
                    mode: 0644
                    content:
                        > listen = 8080
                        > pkg = {pkg}
final_handler:
    name: restart_demo
    systemd:
        name: demo
        state: restarted
```

Note the NestedText wins: `mode: 0644` needs no quotes, and the multiline
`content` is a `>` block — no `|` / indentation-quoting subtleties.

### Fields

- **`params`** — `type` (`string`|`bool`|`number`), `required` (bool),
  `pattern`, `default`. Resolved as `default < host_vars < explicit`.
- **`chunks[].os_family`** — a list; the chunk is skipped entirely if the
  host's family (resolved once via a `setup` call) doesn't match. Ansible's
  OS-dispatch.
- **`when:`** — a small, deliberately non-Turing grammar
  (`bossman/services/when_eval.py`): `not`, `X is [not] defined`, `==`, `!=`,
  and a bare dotted path. **Not** Jinja — a security boundary, since plans may
  be machine-translated from untrusted sources.
- **`register:`** — captures the step result into the shared variable context
  (Ansible's flat namespace). With `loop`, captures `{results: [...],
  changed: bool}`.
- **`loop:`** — a literal list, or a string naming a dotted path (a param or a
  registered result) that resolves to a list at run time. Each iteration
  exposes the element as `item` for `when:` and `{{ item }}`.
- **`on_failure:`** — `abort` (default) or `continue`.
- **`{{ name }}`** — whole-string placeholder substitution (keeps the value's
  native type when the whole string is one placeholder; stringifies when
  embedded). Not Jinja; no filters.
- **`final_handler`** — one step run once after all chunks iff any step
  reported `changed` (Ansible's notify/handler, normalised).

## `tools.d` tasks (the Go agent)

The agent's local named tools in `tools.d/*.nt` load alongside `*.yaml`,
parsing to the same `Task` (`internal/tasks/task.go`). One task file is one
`name` plus exactly one of an `<module>:` mapping, a
`pipeline:`, or a `check:`.

```nestedtext
name: restart_nginx
description: restart nginx
service:
    name: nginx
    state: restarted
```

## Module metadata sidecars

Translated Starlark collection modules keep a metadata sidecar (the argspec)
next to their `.star`. These are read as NestedText `<name>.nt` when present,
falling back to `<name>.yaml` — additive, so the translation pipeline keeps
writing YAML. Backfill the `.nt` sidecars deterministically:

```sh
python bossman/scripts/convert_sidecars_nt.py configs/modules.d
```

## The `yolo-man` CLI

`bossman/yolo-man` (a thin wrapper around `python -m bossman.cli`) is the
command-line front door. Format is chosen by extension: `.nt` → NestedText,
anything else → YAML.

```sh
# Parse + validate a playbook
./yolo-man lint    playbook.nt

# Print the resolved structure (chunks, steps, loop/when/register)
./yolo-man show    playbook.nt

# Convert between YAML and NestedText (deterministic, either direction)
./yolo-man convert playbook.yaml playbook.nt
./yolo-man convert playbook.nt   playbook.yaml

# Run a playbook against an enrolled host (records a PlanRun like the API).
# Needs the Bossman database + TLS identity configured, like the server.
./yolo-man run playbook.nt --host web01 --param pkg=nginx [--check]
```

`--check` is dry-run (check_mode): the agent predicts changes without making
them. `lint`, `show`, and `convert` are pure (no database/agent needed).
