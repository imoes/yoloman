# Config batch pipelines (codec / template / enum / enrich)

Two long-running background pipelines populate `configs/config_codecs.json` and
`configs/config_templates/<name>/` (schema.json + template.j2 + capabilities.json). Both are
**resumable systemd *user* services** (survive reboot via linger). This file is the map — which one is
authoritative, what each pass does, how to restart, and what is redundant.

## TL;DR — which is authoritative

| | `agentic-qualify-packages` (**authoritative**) | `agentic-config-batch` (legacy + partial) |
|---|---|---|
| script | `bossman/scripts/qualify_packages.py` (v6) | `bossman/scripts/config-batch-supervisor.sh` (many scripts) |
| model | **qwen35b** (`Qwen3.6-35B`) | qwen79b via **`/laguna` — DEAD (502)** for the template/enum passes |
| grounding | the package's **real shipped config**, extracted from its `.deb` (+ section-5 man page) | LLM **reconstructs** the config from scratch (hallucination-prone) |
| does | **Qualify → Codec → Template → Enum → Enrich**, per package, over all 9559 packages | separate passes, several now superseded |
| log | `~/.local/state/agentic-batches/qualify.log` | `~/.local/state/agentic-batches/{codec,templates,directives,universe,docaudit}.log` |

**`qualify_packages.py` is the current pipeline.** It does codec + template + enum + enrich in one
grounded pass. The template it emits IS the real shipped config with only site-values turned into
`{{ vars }}` — complete and valid by construction. Prefer it for anything touching templates/enums.

## qualify_packages.py — the v6 pipeline (per package, in order)

1. **Qualify** — the `.deb` actually ships a file under `/etc/` (hard signal) OR a section-5 man page
   exists → the package has config; else skip.
2. **Codec** — classify the file format from the real config + man page → `config_codecs.json`.
3. **Template** — parametrize the real shipped config verbatim (site values → `{{ vars }}`). Man-page
   reconstruction is only the fallback when no `.deb` config is obtainable.
4. **Enum** — mine enums grounded in man page + the real config's own comments + web; every value must
   appear verbatim in a source (ungrounded values are dropped).
5. **Enrich** — on a complete dir, rewrite `template.j2` to be self-documenting + Ansible-safe and emit
   `capabilities.json` (the Lego provides/requires contract), gated by `enrich_gates`' five checks.

State: `configs/.qualify_pipeline_state.json` keyed by `PIPELINE_VERSION`. Reprocesses the existing
~3.2k dirs too (that is why v6 re-runs all). `.deb` temp trees under `/data1/agentic-dev-tmp`.

Restart:
```bash
systemctl --user restart agentic-qualify-packages.service
tail -f ~/.local/state/agentic-batches/qualify.log
```

## config-batch-supervisor.sh — legacy + still-unique passes

Runs many scripts in a loop. Split them:

**REDUNDANT with qualify (and hardcoded to the dead `/laguna` → 502 retry loop):**
- `mine_codec_templates.py` — a template for every codec'd file (LLM-reconstructed). **Superseded** by
  qualify's grounded Template stage. This is the pass that hangs (`templates.log`, `retry N/7 … 502`).
- `batch_config_templates.py` — a template for each `codec:"none"` free-form file. Superseded.
- `mine_schema_enums.py` — enum dropdowns (web-grounded). Superseded by qualify's Enum stage.
- `mine_ansible_templates.py` — web/Ansible-role-grounded templates (list-of-object vars, e.g. vhosts).
  Different grounding from qualify; keep only if the table-editor variables it adds are still wanted —
  but it too points at dead `/laguna`.

**Still unique (NOT produced by qualify) — keep:**
- `classify_config_codecs.py` — codec classification pass (qwen35b path in the app settings).
- `mine_directive_values.py` — per-directive value catalog `config_directives.json` (the ADMX-style
  gpedit listboxes). qualify does not produce this.
- `fetch_package_universe.py` + `classify_package_universe.py` → `package_universe_real.json`, which
  **qualify consumes** — so this must keep running to feed qualify.
- `verify_package_docs.py` → `package_doc_audit.json` (doc-completeness audit). Unique.
- `enrich_schema_enums.py` — links `config_directives.json` → schema field enums (not on laguna).

**Recommendation:** retire the four `/laguna` template/enum passes (comment them out in the supervisor —
it is "the batch script", edited in one place, no per-python-script churn), leaving qualify as the sole
owner of templates+enums and config-batch as the owner of the ADMX/universe/doc-audit passes it alone
produces. That also ends the 502 retry loop without repointing any endpoint.

## Endpoints (llm.example.internal, verified 2026-08-02)

| path | model | state |
|---|---|---|
| `/qwen35b` | `Qwen3.6-35B-A3B-UD-Q4_K_XL` | live — qualify + app chat (`chat_base_url`) |
| `/qwen79b` | `qwen3next-79b` | live (reasoning model; needs `enable_thinking:false`) |
| `/laguna` | (was `laguna`) | **DEAD — 502**; the legacy template/enum passes still point here |
| `/embed` | `bge-m3` | live — embeddings |

App settings (`bossman/bossman/config.py`): `chat_base_url=/qwen35b`, `hermes_web_base_url=/laguna`
(**also dead** — the "hermes-web" chat model in the UI 502s until repointed).

---

## The RedHat side (2026-08-20) — same stages, different package manager

`qualify_packages.py` grounds on `.deb` contents, so everything it produced is Debian. Measured: of 4473
paths in the codec registry, **7** looked RedHat-specific and 321 Debian-specific — for RedHat the package
NAMES were curated but the FILES were never looked at, and `/etc/httpd/conf/httpd.conf` is not
`/etc/apache2/apache2.conf`.

Everything below runs **in an EL9 container behind the proxy** (`http://host.example.internal:80` — without it
`dnf` returns 0 packages, which is easy to misread as "the repos are dead") and installs nothing.

| script | what it does | why not the obvious way |
|---|---|---|
| `rh_verify_claims.py` | checks a curated `redhat.config_path` with `dnf repoquery -l` / `rpm -qcp` | asserting a path is not knowing it: of 40 claims, 23 held and 17 did not |
| `rh_what_ships.py` | lists what a package really ships under `/etc` | "no RPM ships /etc/spamassassin/local.cf" means the PATH is Debian's, not that the file does not exist |
| `rh_extract_configs.py` | `dnf download` + unpack, returns the config TEXT | the RPM twin of `_deb_config`; `cpio` is absent from `almalinux:9`, so it prefers `rpm2archive` |
| `rh_universe.py` | the whole universe from `filelists.xml` | `repoquery -l` per package is 32445 round trips; the repo metadata IS the path→package index. **Compression differs per repo** — AlmaLinux `.gz`, EPEL `.xz` — and a `.gz`-only glob silently read 4 repos of 5 |
| `rh_harvest_corpus.py` | every `/etc` file of all 1902 packages, one download per PACKAGE | 8843 paths live in 1902 packages; per-path would refetch the same RPM a dozen times. Resumable, and a `dnf download` timeout is a fact about ONE package |
| `rh_mine_directives.py` | fills the directive catalog | twin inheritance first (a directive belongs to the SOFTWARE), then qwen35b — see the gate below |
| `rh_make_templates.py` | parametrizes the freeform role files | a template CANNOT be inherited from the Debian twin: it reproduces a whole FILE |

Result: universe **349 guessed → 1902 measured** packages / 8843 paths; corpus 8261 files; codecs decided at
the bytes (**4219 codec / 3023 freeform / 508 executable / 413 no-evidence**); 14 role templates.

### The gate that stops a catalog from lying

`/etc/redis/redis.conf` was once mined into 18 directives named `SSL_verify_mode`, `sentinels_cnx_timeout` —
the options of the **Perl module** `Redis(3pm)`, which is what a man lookup for package "redis" finds.
Coverage of the file's 41 real keys: **0%**. So before mining, `doc_is_about()` requires that a fifth of the
file's own keys appear in the documentation; failing that the web source is tried, and failing that the
**file's own comments** are used (`redis.conf` is 88% comment lines — they document every setting above it,
and they cannot be about another program). `check_directive_coverage.py` is the acceptance: how many of the
keys the SHIPPED file sets are described.

### Verifying a generated template: invariants first, then an independent judge

`verify_templates.py` runs five invariants — parses and renders · the shipped file's lines survive · every
placeholder is declared · the sample's VALUES reach the output · at least one placeholder is on a
non-comment line — and only then asks a model that did **not** write the template (`--judge`, engines
`hermes` / `laguna` / `claude`). Note: in this repo "Hermes" means `HermesWebBackend` on `.../laguna`, which
is **502**; what works is the Hermes agent CLI (`hermes -z … --yolo`, qwen3.5-35b) and, through it,
OpenRouter `poolside/laguna-s-2.1`.

Every defect the judge found became a mechanical repair, and these run **in the generator**, in this order:

1. `escape_template_literals.py` — the file's own brace sequences become literals; a `;` swallowed into a
   placeholder moves back out. **Idempotent**: `{{ '{{' }}` contains `{{`, so a second pass used to escape
   the escape.
2. `repair_template_text.py` — lines the JSON envelope mangled (backslashes) restored to the shipped bytes.
3. `activate_commented_settings.py` — `#Key {{ var }}` becomes `{% if var %}Key …{% else %}#shipped{% endif %}`,
   so the knob does something. Ambiguous names (collectd repeats `#File` across plugin blocks) are **undone**,
   not guessed.
4. `align_template_defaults.py` — every default taken from the shipped file (bind9 rendered `recursion True;`
   where named.conf wants `yes`), abstaining when the line is not uniquely identifiable.

**The acceptance is the codec round-trip's shape:** rendered with its OWN defaults, a template must reproduce
the file the package ships.
