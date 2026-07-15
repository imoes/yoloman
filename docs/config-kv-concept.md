# Configuration tab — course correction: use the codecs, templates, and the document loop

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

- **K1 — value editor via the document loop** (fixes the miss directly):
  key-value table editor for codec'd files; Bossman proxies
  `POST /agents/{id}/state/plan` + `/state/apply` (missing today — only
  observed/generations/rollback exist); Preview renders plan.changes[].changed;
  Apply creates a generation (F2's history/rollback then applies to every
  edit for free). Codec extension: null = delete-key (keyvalue + ini first).
- **K2 — template binding**: Bossman endpoint serving
  `configs/config_templates/` (name, schema, sample); match discovered path ↔
  template name (chrony.conf→chrony, rsyslog.conf→rsyslog, /etc/hosts→hosts,
  …); schema-driven form; preview = template_render dry-run + unified diff vs
  raw; apply through the document loop.
- **K3 — values in Bossman's DB**: persist each host's edited values as
  desired state (per path); drift view (observed ≠ desired) on the tab;
  this is the fleet-side half of the key-value database.
- **K4 — scope**: attach the same values document to an OU/group (GPO-style),
  compiled into hosts' desired state — config policy, Host A = Host B.

Order: K1 → K2 → K3 → K4. Each block: implement → Playwright verify against
docker-test → update docs/ui-parity.md → commit (no push without approval).

Raw-editor code from 0.44.0 stays as tier 3 but stops being the default edit
path (K1 replaces it for codec'd files, K2 for templated ones).
