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
