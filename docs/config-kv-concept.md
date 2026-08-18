# Configuration tab — course correction: use the codecs, templates, and the document loop

> **Where this lives now (2026-08-18):** the Configuration TAB was folded into the
> Management console — **Management ▸ Configuration ▸ Settings / Effective thresholds / Desired
> state**. The tab names below are kept as written because this file records a decision made when
> they were accurate; only the location changed.

**The mistake (user feedback, 2026-07-15):** the Configuration tab grew a raw-text
editor ("edit the file 1:1, push via copy"). That is vi-over-HTTP — it bypasses
everything the architecture is for. "Wozu haben wir die jinja2 templates und die
Codecs, wenn wir die Konfigdateien nur 1:1 darstellen? Wozu eine keyvalue
Datenbank, wenn wir die Vorteile nicht nutzen?"

**The point of the architecture:** a config file is not text — it is **values**.

- Class-A codec: file ↔ structured values, bidirectional, structure-preserving
  merge (comments survive). The values ARE the key-value database.
- Class-B template: values + Jinja2 → the whole file. The values are the
  document; the file is derived output.
- Document loop (already live in the agent, used by F2's rollback UI):
  `POST /state/plan` (per-key diff `changed: {key: [before, after]}`) →
  `POST /state/apply` (writes + records a **generation**) → rollback.

**Editing a config must mean: edit values → plan (diff) → apply (generation).**
Never "textarea the file". The raw text stays as a read-only view / last-resort
fallback only.

## Target UX per config card (three tiers)

1. **Template-managed** (file has a matching `configs/config_templates/<name>/`):
   badge "template: chrony". Edit = a **form generated from schema.json**
   (lists get add/remove rows). Preview = render via `template_render`
   (dry-run) + diff against the live file. Apply = render + write through
   `state/apply` (generation). On docker-test this immediately covers
   chrony.conf, rsyslog.conf, /etc/hosts.
2. **Codec-managed** (keyvalue/ini/yaml/xml, no template): edit = a
   **key-value table** (rows: key | value | delete; add-row). Preview =
   `state/plan` with a one-resource Document → render the per-key diff (the
   same renderer the rollback preview already uses). Apply = `state/apply` →
   generation. Deleting a key needs a small codec extension: `value: null`
   means **absent** — the merge removes just that line (structure-preserving).
3. **Raw fallback** (no codec, no template — motd, issue, hosts.allow): keep
   the current raw view; editing stays possible but is explicitly the fallback
   tier, labelled as such.

## Why this uses the "key-value database"

The edited values become the desired state: stored per host (Bossman),
diffable (plan), versioned (generations), roll-backable — and distributable:
the same values object can hang on an OU/group (policy) so Host A = Host B.
Ad-hoc pushes (tools/config, tools/copy) skip all of that.

## Blocks

- **K1 — value editor via the document loop** ✅ DONE + live-verified (0.45.0):
  key-value table editor for codec'd files (Key | Value | delete, add-row);
  Bossman proxies `POST /agents/{id}/state/plan` + `/state/apply`; AgentClient
  state_plan/state_apply. Preview renders plan.changes[].changed (per-key
  before→after); Apply writes through the codec merge and records a generation
  (F2 rollback then covers every edit). Codec extension: a null value =
  delete-key, structure-preserving (keyValueCodec; test
  TestConfigKeyValueNullDeletesKey). Verified on docker-test: edit chrony
  makestep + delete rtcsync → plan diff → apply → host file changed
  (comments intact, rtcsync line gone), generation created, reverted cleanly;
  same flow through the UI KV table. ini null-delete + the KV editor for ini
  still to come.
- **K2 — template binding** ✅ DONE + live-verified (0.46.0): Bossman endpoint serving
  `configs/config_templates/` (name, schema, sample); match discovered path ↔
  template name (chrony.conf→chrony, rsyslog.conf→rsyslog, /etc/hosts→hosts,
  …); schema-driven form; preview = template_render dry-run + unified diff vs
  raw; apply through the document loop.
- **K3 — values in Bossman's DB** ✅ DONE + live-verified: persist each host's edited values as
  desired state (per path); drift view (observed ≠ desired) on the tab;
  this is the fleet-side half of the key-value database.
- **K4 — scope** ✅ DONE + live-verified: attach the same values document to an OU/group (GPO-style),
  compiled into hosts' desired state — config policy, Host A = Host B.
  - Authored two ways: (a) from a host's Configuration tab via the scope
    selector (host/OU/group), and (b) — matching the Windows model where the
    host shows the *resolved* result and policies are authored at scope —
    from the **OU/Policy console**: right-click an OU or host group →
    *Config setting…* → dialog (file/codec/key/value or removed). This POSTs
    `/api/v1/config-policies` (agent-free: works for an OU with no reachable
    host yet), upserts the ConfigPolicy, and converges every reachable member.

Order: K1 → K2 → K3 → K4. Each block: implement → Playwright verify against
docker-test → update docs/ui-parity.md → commit (no push without approval).

Raw-editor code from 0.44.0 stays as tier 3 but stops being the default edit
path (K1 replaces it for codec'd files, K2 for templated ones).
