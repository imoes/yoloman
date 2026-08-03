# Importing foreign orchestration code (Ansible · Salt · Puppet · Chef)

Onboarding an existing shop means ingesting what it already has. Nobody pastes a role one file at a time, so
the import surface is a **whole checked-out tree** — role, formula, module, cookbook — and the honest question
is not "does it work" but "**what fraction of real upstream code does it take, and what does it refuse**".

This file records that measurement against four mainstream upstream projects, so the next person doesn't have
to re-derive it and doesn't have to trust a claim.

## The endpoint

`POST /api/v1/plans/import-bulk`

```json
{ "files": [{"path": "tasks/main.yml", "text": "…"}], "folder": "imported/nginx", "dry_run": true }
→ { "imported": [{"path","prefix","name","version","kind"}],
    "skipped":  [{"path","reason"}],
    "failed":   [{"path","error"}] }
```

Three design rules, each one a bug that was found by testing against real trees:

1. **Classify positively, not negatively.** A tree is *mostly not plans* — templates, defaults, metadata,
   fixtures, specs. Classification (`plan_store.detect_plan_format`) matches on directory + extension
   (`tasks/*.yml` → ansible, `*.sls` → salt, `manifests/*.pp` → puppet, `recipes|resources/*.rb` → chef).
   An earlier skip-list approach mis-filed real code across frameworks: `kitchen.yml`/`pdk.yaml` read as
   Ansible, `lib/puppet/functions/*.rb` and `test/**/*_spec.rb` as Chef, `test/salt/pillar/*.sls` as Salt.
2. **Isolate per file.** One exotic file must not lose a 400-file tree. Each parser raises its own exception
   type (`PlanError`, `PlaybookError`, `NTRunbookError`, …) — catching only `PlanError` let a single bad file
   500 the whole request, which is how this was found.
3. **A preview must actually parse.** `dry_run` originally reported every classified file as importable
   without parsing it, i.e. the preview promised results the real run then refused. It now runs the parser
   and only skips the write.

Names come from the **full relative path** joined with dashes (`config/certificates/clean.sls` →
`config-certificates-clean`). Using the basename silently overwrote: `apache/clean.sls` and
`apache/config/certificates/clean.sls` both wanted to be `clean`.

## Where an import lands: runbook store vs. plan store

There are two engines with **different task vocabularies** (see CODE_CARD.md). Routing matters more than any
parser tweak:

| tree | measured with the plan loader | measured with the runbook parser |
|---|---|---|
| `geerlingguy/ansible-role-nginx` | 4 / 10 task files | **10 / 10** |

So Ansible task files are stored as **runbooks**; Salt/Puppet/Chef stay on the **plan** store because their
parsers emit plan bodies. Re-importing the same tree updates in place (no 409, no duplicates).

## Measured coverage (upstream HEAD samples, 2026-08)

| tree | files sent | imported | not a plan | refused |
|---|---|---|---|---|
| `geerlingguy/ansible-role-nginx` | 34 | **10** | 24 | **0** |
| `saltstack-formulas/apache-formula` | 179 | 0 | 120 | 59 |
| `puppetlabs/puppetlabs-apache` | 427 | 0 | 303 | 124 |
| `sous-chefs/nginx` | 80 | 0 | 76 | 4 |

Ansible — our native surface — is complete. The other three are **parser scope**, not bugs, and each tree
fails for a single reason:

### Salt — Jinja preprocessing + `include` (59 files)
`.sls` is a Jinja template *then* YAML. The formula opens with
`{%- set tplroot = tpldir.split('/')[0] %}`, so `yaml.safe_load` dies on `%` before any Salt semantics are
reached. 8 further files use `include:`, which `salt_parser` reports as roadmap.
**To close:** render the file through gonja/Jinja2 with the Salt context (`tpldir`, `grains`, `pillar`,
`salt[…]`) before parsing, then implement `include` as a step that references another stored plan.

### Puppet — only flat resource declarations (124 files)
`puppet_parser` handles resource declarations; a real module is almost entirely `class`/`define` bodies with
conditionals and chaining. Every `manifests/*.pp` in puppetlabs-apache is a class.
**To close:** parse `class`/`define` into parameterised plans (their params map to plan `parameters`), and
`if`/`unless`/`case` into step `when` conditions.

### Chef — the custom-resource DSL (4 files)
Only `resources/*.rb` fail, all on `unified_mode true` at line 18 — a modern custom-resource keyword the
parser doesn't know. The `recipes/` half is not the blocker; sous-chefs/nginx simply *is* a resource
cookbook.
**To close:** recognise the custom-resource vocabulary (`unified_mode`, `property`, `action :x do`), which
means mapping a Chef resource onto a *parameterised plan*, not onto a step.

## Ansible surface notes

Two constructs were added to `services/ansible_playbook.py` to reach 10/10, both documented Ansible rules
rather than guesses:

- **`key=value` free-form** for any module (`apt: update_cache=yes cache_valid_time=86400`). k=v is untyped,
  so coercion is deliberately narrow: Ansible's own boolean literals (`yes|no|true|false|on|off`) and plain
  integers become typed values; everything else stays a string so quoted values survive.
- **Documented bare-scalar shorthands** only (`include_vars: x.yml` == `file: x.yml`). Any other bare scalar
  would be Ansible's `_raw_params`, which only the module itself can interpret — that case fails loudly with
  the reason, because guessing would run a *different task than the author wrote*.

`notify` also accepts Ansible's scalar shorthand (`notify: restart nginx`) in the runbook path. It is still
refused in the **plan** path, deliberately: the plan engine has no handler concept, and accepting a keyword
the engine then ignores would hand back a document promising a handler that never runs.
