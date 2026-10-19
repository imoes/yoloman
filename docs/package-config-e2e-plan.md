# Package-config e2e: the remaining work

As of 2026-10-11, 14:40. This is the list I work from. Each item states the **measured** current state and where the
number comes from, the steps, and when the item counts as done. An item is ticked only when its "done when" is met
and committed. Anything not on this list is not planned. A new finding becomes a new item here first.

Branch `feat/package-config-e2e`, not pushed. Pushing waits for an explicit go from the user.

## Where it stands (measured)

| What | Value | Source |
|---|---|---|
| Templates on disk | 5876 (Debian 5467, AlmaLinux 409) | `configs/config_templates/*/template.j2` |
| Reachable (bound by index or catalog) | 1127; 4748 withheld — 1456 after the projection was regenerated (E4) | `configs/config_templates_manifest.json` |
| Stage 1: renders its own sample (gonja) | 5781 / 5876 = 98.4 % | `configs/template_render_broken.json` (95) |
| Stage 2: written by the agent on a host with the package installed | 853 / 857 templates on wizard/rule-template routes | `configs/package_e2e_results.jsonl` × worklist |
| Stage 3: accepted by the package's own checker | 27 templates; 24 checkers known (15 Debian, 9 EL) | `configs/package_validators.json` |
| Stage 4: catalog role compliant, daemon up 10 s later | 235 / 298 (last full re-run, agent 0.57.83) | `configs/package_e2e_bossman_results.jsonl` |
| Stage 5: defaults reproduce the shipped file | measured one by one (~100), not systematically | — |
| Worklist Debian | wizard 470, rule-template 128, rule-codec 600, no-config 6599, **unrouted 758** | `configs/package_e2e_worklist.json` |
| Worklist AlmaLinux | wizard 61, rule-template 294, rule-codec 924, no-config 36, **unrouted 587** | same |
| LLM queue | RedHat universe 223 / 1100; slow on very large files (504 from the gateway, up to 7 retries) | `~/.local/state/agentic-batches/qualify.log` |
| Agent | 0.57.83 on the test images; the manpage renderer fixes since then are unreleased | `VERSION`, git log |

## A. Regressions from the last full re-run (first)

The re-run on agent 0.57.83 ended at 235 compliant; the run before it at 238. Three roles changed:

- [x] **A1 bip**: `noncompliant`, "Unit process … (bip) remains running after unit stopped". Cause: bip.service is
  `Type=forking` without `PIDFile`, so systemd guesses the main process. Fixed in the role: catalog init adds a
  drop-in `PIDFile=/var/lib/bip/bip.pid` when the unit has none. Compliant in 3 runs in a row (21.9 s, 16.2 s, 16.3 s).
- [x] **A2 gnunet.conf**: `noncompliant` again, although the log-file init made it compliant once. Cause: the shipped
  unit is `Type=forking` around `gnunet-arm -s` without a PIDFile; systemd guesses the main process (often MainPID=0),
  and about 1 restart in 5 ended "Deactivated successfully" with every gnunet process gone (measured on a kept host:
  5 restarts, 1 dead). The role's init now runs ARM in the foreground (`Type=simple`, libexec path resolved per
  architecture): 20/20 restarts active, a stop leaves no process, compliant in 3 Bossman runs in a row.
- [x] **A3 sshd on AlmaLinux**: `dnf install` failed with "No such file … openssh-9.9p1-12…rpm" in the dnf cache.
  The first guess, stale baked metadata, was WRONG: that version was on the mirror, and the same install in the old
  image (old agent, same proxy) succeeded afterwards — a failed download, not stale metadata. Done: (a) the images
  refresh their baked index once a day of building (`REPO_SNAPSHOT` build arg, part of the tag hash); (b) the agent's
  dnf/yum/dnf5 path drops the metadata and retries ONCE when a package file could not be fetched (tests: the retry
  runs install → clean metadata → install; a non-fetch failure is not retried; a second failure says a refresh was
  tried). sshd/AlmaLinux compliant twice on the rebuilt images (16.9 s, 16.2 s). The retry itself ran only in unit
  tests: the failure did not reproduce on a real host.
- [x] **A4 Deleting a kept host's agent returned 500** (found while cleaning up A1's kept host): FK
  `service_state_history_agent_id_fkey`. The endpoint did delete the history, but the poller committed a new state
  change in between. Fixed: `purge_agent_rows` locks the agent row (`FOR UPDATE`) first; test
  `test_delete_agent_blocks_a_concurrent_state_change_insert` (fails without the lock). The runner ignored the delete
  status, so 36 agents of deleted test pods had accumulated; all 36 deleted with 204 after the fix, and the runner now
  writes `cleanup_failed` into the result row.

## B. Agent release 0.57.84

- [x] **B1** Agent 0.57.84 built (deb + rpm) with the manpage renderer fixes (919d5d208) and A3's dnf retry; images
  `pkg-e2e/debian-trixie:0.57.84-dd71555bc2`, `pkg-e2e/almalinux9:0.57.84-6db0460f9e` and their systemd variants loaded.
- [x] **B2** `man_search` over Bossman's MCP (temporary API token, deleted, 204) on a fresh Debian host (1370 pages)
  and a fresh AlmaLinux host (338 pages): search "ssh daemon" → sshd(8), sshd_config(5); full text PermitRootLogin;
  read sshd_config(5) with grep PasswordAuthentication → its definition first; sshd(8) heading FILES. Found on the way:
  `pages_installed` was the count after the section filter (1370 for a search, 135 for a read on the same host) —
  fixed (host count always, `pages_in_section` for the filtered one), test added; ships with the next agent build.
  Also found: a second runner process re-used a NodePort a kept host still held ("provided port is already
  allocated"); the runner now skips ports any Service in the cluster holds.

## C. UI

- [x] **C1** Full Playwright suite on the current UI and backend: 124 passed, 1 failed, 5 skipped (20.9 min). The one
  failure was the product, not the test: on AlmaLinux the HAProxy wizard greyed out every field, because the role's
  template and `haproxy-redhat` shared **no** field name (0 of 19) — the role was not configurable on EL at all.
  Fixed in `haproxy-redhat` (G5 below); the e2e-rh-1 block re-run: 14 passed, 2 skipped (preconditions: iodined is
  Debian-only; no rollback preview open). The skips of the full run are the same kind.
  Regression run after the wizard union / index / engine changes (2026-10-11 night): **134 passed, 0 failed,
  6 skipped** (6.6 min).

## D. Pod path, re-run with installs through the agent

- [x] **D1** Done 2026-10-11 — table and named causes in `docs/package-config-e2e.md` ("Agent in a pod"): pass 49,
  pass-unverified 2389, install-only 26, install-failed 13, render-failed 0, validate-failed 0. The pod e2e now installs through the agent's package module (with recommends, as a managed host does).
  Re-run the routed packages (`--routes wizard,rule-template,rule-codec`, 2477) and compare with the last run
  (2406 pass-unverified, 34 pass, 26 install-only, 8 install-failed, 2 render-failed, 1 pod-failed). Every new
  failure is classified. Done when the table is updated in `docs/package-config-e2e.md`.

## E. Template verification (the stages above)

- [x] **E1 Stage 5, systematic.** Done: every reachable unit has a verdict; counts in `docs/package-config-e2e.md` ("Stage 5"). For each of the reachable templates (1456 after E4's regeneration; 3213 units of
  template × family × path; tool `bossman/bossman/tools/template_shipped_fidelity.py`): fetch the package that ships the target
  file (Debian: Contents index; EL: `rpm_source`), render the template with its defaults, compare with the shipped
  file (byte-exact and on active lines), and record the result in `configs/template_shipped_fidelity.json`
  (template, package, verdict: identical / same-settings / differs / no-shipped-file). Done when every reachable
  template has a verdict and the counts are in the docs.
- [x] **E2a Role templates bound to a namesake file** (found by E1's first unit, haproxy): the recorded index bound the
  haproxy.cfg template to /etc/sysconfig/haproxy and /etc/logrotate.d/haproxy, `cron` (crontab) to /etc/pam.d/cron
  and /etc/default/cron, `redis` to /etc/raddb/mods-available/redis — 23 bindings, all by codec NAME. Configure would
  have written a crontab over a PAM file. Fixed in `template_index`: the catalog counts as a record of its role
  template's file (renders(), and the record-beats-name rule), a namesake in another file is refused with the reason;
  the same file in another location stays allowed. Tests on fixtures and on the real corpus per family; projection
  regenerated: 0 of the 23 left.
- [x] **E2d Reachable templates that do not render with their own defaults** (E1: 14 templates, 36 units, all
  index-only). gonja fails on attribute access to an unset object (`{{ pve.auth_url }}` → "Getitem on None") and on
  `x.items()`; jinja2 (the pipeline's check) renders both empty. `batch_verify.null_safe_objects` guards every level
  of such chains (`((a | default({})).b | default({})).c`, `.items()` → `| dictsort`): 10 fixed; 3 by hand (utrans-rc
  read `values.x` for top-level fields; config.xml used a non-filter `dir` → `dirname`; lighttpd.conf ran `indent`
  before `default`). Each verified with the agent's engine on defaults AND sample. server.yaml stays refusing: its
  `| mandatory` asks for site values (database.uri, auth.secret_key) — a deliberate refusal, not a defect.
- [x] **E2 Fix what E1 finds, deterministically first.** **Done (2026-10-12):** every reachable `differs` unit has a
  recorded reason in `configs/template_differs_reasons.json` (`bossman/bossman/tools/explain_differs.py`), 0 without
  one. Catalog Debian: a rebuild would lose operator fields 122 · format the builder cannot field 43 · rebuild not
  faithful 5 · repair refused 5 · runtime-vetoed 3 · shared with another family's file 1 · file unavailable 1; EL
  catalog: loses fields 8, others 4. All units: loses fields 531, unfieldable 291, repair refused 133, unfaithful 99,
  file unavailable 72, shared 15, vetoed 3. What remains is a per-role decision (keep the model's extra fields or the
  shipped file's layout), not a mechanical repair. **REDONE with a safe chain (2026-10-11 night).** The first
  passes below were partly harmful: the chain's fuzzy line restore (difflib "closest shipped line") turned containerd's
  three different TOML table headers into the shipped one (duplicated tables), and its escape step made a valid
  `{% set … {…} %}` block text; both looked like improvements to stage 5, and the general pass even re-repaired a
  catalog template after its runtime revert. Fixed: whitespace-only restore, never a line with `{%`, escape only for a
  template that does not parse; the general pass excludes catalog units; a runtime revert is a permanent veto. All
  174 repaired templates were reset to their pre-repair state (910e9dff6^) and repaired again: catalog 45 kept (19 to
  same-settings/identical), runtime check of the touched service roles — no regression; non-catalog 62 of 714 kept; a
  git-based sibling check over all 109 changed templates: 0 worse in any unit. Debian catalog units now identical 43 ·
  same-settings 167 · differs 201; EL catalog 19 · 9 · 12. Second catalog pass after the inline-default fix: 16 more
  kept, runtime check — one regression (sniproxy: the inline step took a `fallback` value from another block of the
  shipped file; reverted, vetoed); 15 kept. Residual risk recorded: that step can pick a unique but wrong line, which
  only a runtime check catches. **Rebuilds (2026-10-12):** of the 197 still-differing Debian catalog templates, 18
  rebuild from the shipped file with their OWN field names (`--names-from` on themselves) and lose no field; taken
  (plus guymager, whose only lost field was the bogus `sample_values`), all identical/same-settings, sibling units
  not worse (awstats skipped: EL worse), touched service roles compliant (corosync-qdevice fails as before: no
  cluster). Left for a per-role decision: 30 would lose 1–2 fields (some real — apache2 `virtual_hosts`, fail2ban
  `jails`), 100 more than two, 43 are formats the builder cannot field (XML, JSON, blocks). The text below describes
  the first, superseded passes.
  **Catalog pass applied (2026-10-11 evening, superseded):** 73 templates
  improved, 25 of them to same-settings/identical; Debian catalog units now identical 44 · same-settings 172 · differs
  195 (was 39 · 152 · 220). Runtime check of the affected service roles on the Bossman path: no role that was
  compliant before is worse after. On the way the chain itself switched a COMMENT about a loop item on as a setting
  (postfix: `# TLS setting: {{ key }}` — the loop runs zero times with defaults, so stage 5 could not see it; postfix
  refused main.cf): activate/deactivate now touch only schema fields outside loops. Two repairs still broke their
  daemon (containerd: duplicated TOML table; lcd4linux) and were reverted with the reason in the repairs log — the
  runtime outranks the fidelity measure. Remaining Debian catalog `differs` are mostly rewritten files (A) and mixed
  cases (E) — a per-role decision, not a mechanical one.
  **Non-catalog pass:** 119 of 879 improved. A check against git found the repair had made OTHER units of the same
  template worse: a template bound on both families was repaired against the EL file and lost the Debian file's
  settings (17 units; NetworkManager.conf already in the catalog pass — its else branch became RHEL's
  `#plugins=keyfile,ifcfg-rh`). Rule added: a repair is measured against EVERY unit of its template and kept only if
  none gets worse (`repair_one(siblings=…)`, test); the damaged templates were restored and re-tried — all refused.
  Lesson: the repairs log is overwritten by later runs, so "what did the repair change" is answered by git, not by
  the log. Such shared templates need their own `-redhat` template (G5 step 2), not a compromise — **done for 14**
  (c-icap, chrony, gammu-smsdrc, gkrellmd, login.defs, minidlna, mosquitto, munin, NetworkManager, ocserv,
  opencryptoki, pgbouncer, prosody, radicale-config): each built from the RPM's file with the Debian template's
  field names, each identical to the RPM file; Debian untouched; the chrony role on EL now writes the RPM's
  chrony.conf (compliant, `chronyd -p` accepts it). Not built: linuxptp, nsca-ng-server (no EL file), nsd, receptor
  (no directive the builder can field).
  **Not runtime-checked yet:** the non-catalog repairs (index-only templates) — the pod path (D1) is their check. E1 (first full pass, 2026-10-11): Debian catalog-role units
  identical 39 · same-settings 152 · **differs 220** · no-shipped-file 21; EL catalog 10 · 10 · **20** · 1. The 220 by
  shape: rewritten 72, examples switched on 64, a few values 42, mixed 32, settings dropped 10. Rebuilding from the
  shipped file (template_from_shipped) keeps every old field in only 10 of them — not the main path.
  The repair chain (`template_repair_chain`) had NO caller; now `bossman/bossman/tools/repair_from_shipped.py` runs
  it per `differs` unit against the shipped file and keeps a repair only when the verdict improves and the sample
  still renders (log: `configs/template_shipped_repairs.json`). Chain fixes on the way: model activations with
  filters (`{{ x | default('none') }}`) are now put back behind their comment, guarded with present() and their
  default nulled; activate_expressions no longer glues a one-line block to the next line; a new step splits lines an
  earlier pass glued. Dry run on 30 Debian catalog roles: 13 improved (4 to same-settings), 7 before the fixes. For `differs`, the tools in order: `activate_expressions`,
  `template_from_shipped` (field names stay the directive names), hand fix for catalog roles. Each fix is checked by
  re-rendering against the shipped file. Done when no reachable template differs without a recorded reason.
- [x] **E3 Stage 3, without the LLM.** Tool `bossman/bossman/tools/probe_checkers.py`: a fresh pod per (family,
  package), the package installed by the agent, the checker run on the file the package SHIPS; only `verified` is
  written to `configs/package_validators.json`; every outcome in `configs/checker_probe_results.json`.
  **24 verified** — Debian: named-checkconf, postfix check, haproxy -c, squid -k parse, sshd -t, apache2ctl -t,
  nginx -t, doveconf -n, opendmarc -n, dhcpd -t, promtool check config, cupsd -t (cups-daemon and cups); AlmaLinux:
  the same for bind, postfix, haproxy, squid, httpd, nginx, dovecot, opendmarc, dhcp-server, cups, and sshd with a
  throwaway host key (EL creates host keys on first start, so plain `sshd -t` said "no hostkeys available").
  **Rejected, with the reason:** miredo-checkconf (resolves the Teredo server name — depends on the host's DNS, not
  only on the file); keepalived -t on EL (the shipped example itself fails: garp interval 0, MASTER without the
  address). **No shipped file to verify against:** keepalived (Debian), sssd (both).
  Then the roles with a new checker ran on the Bossman path: 23/23 compliant, and the checker accepted every written
  file — after two runner fixes found on the way: the checker ran through the `command` module (no shell, so
  `$(dirname …)` reached postfix literally), now `shell`; and a role whose file the checker rejected was still
  reported `compliant` next to rc=1, now `validate-failed` with the role's state kept beside it.
  Catalog roles with a verified checker: Debian 28, AlmaLinux 20 (the runner now takes the first of ALL the role's
  packages that has one — cupsd lives in cups-daemon).
- [x] **E2b `for k, v in X | dict2items` renders `key = value`** (found by the postfix checker: "unused parameter:
  key=value"). Measured with the agent's engine: two loop variables over dict2items unpack the `{key:, value:}`
  object into its field NAMES. 121 templates had it; rewritten to `| dictsort` (same pairs, sorted), each rendered
  before and after with defaults and sample — none broke; 20 sample renders lost the literal `key = value`; 10
  default renders changed, e.g. containerd's config.toml wrote `KEY = "value"` and now writes the real option
  (where a second defect showed: `| upper` on a case-sensitive key, and a string "true" for a boolean — fixed,
  the containerd checker accepts the role's file). The contract (`batch_verify.verify_template`) now refuses the
  construct, and the qualify pipeline rewrites it before writing any template.
- [x] **E2c Family templates offered to another family:** the debian index block bound 297 `-redhat` templates
  (grep-redhat on /etc/GREP_COLORS …). A template recorded for another family is now withdrawn from a family's
  index with verdict `other-family` (named); base keeps it. 0 left in the debian block.
- [x] **E4 Withheld templates (4750).** **Explained (2026-10-11 night, agent 0.57.86 manifest):** reachable 1497 of
  5924 on disk (morning: 1127); withheld 4427 = recovery found no /etc file in the package 2221 · no shipped file
  matches the template 1039 · withdrawn by the index's own rules 290 · in the index's conflicts 182 · cron/init/script
  paths in no index block 215 · no package downloadable 177 · script, not configuration 142 · does not render its
  sample 81 · EL family templates the gate refuses (scripts, `.sample`, no placed field) 65 · bound to another
  template 6 · ambiguous 4 · no target 5. The 65 used to vanish from the index silently; they are now listed in
  `withdrawn` (verdict `not-configurable`, test). A further gain needs new templates, not bindings. Count how many have a resolvable target (a `.deb` that ships a file the
  template renders). Bind them deterministically (`witness: deb-content`, as in plan 1d), or record why not.
  Done when the withheld count is explained by category.
  First count (2026-10-11, offline): recovery no-etc-file 2223 · no-match 1039 · no-package 177 · script-not-config 142
  · does-not-render 81 · ambiguous 4 · no target, no recovery row 5 · has a target_path but is not bound 1079.
  The largest group of the 1079 — 359 EL family templates (witness rpm) "in no redhat index block" — was NOT a product
  gap: the live `/config-templates/index?family=redhat` binds them (e.g. avrdude-redhat, dhcp-server-redhat). The
  recorded projection `configs/config_template_index.json` (what the standalone agent and the manifest read) was
  from 2026-10-09, before the RedHat qualify run. Regenerated (`bossman/scripts/export_agent_config_projection.py
  --write`): reachable templates 1127 → 1456. The withheld categories are recounted after the next agent build's
  manifest. Lesson: the projection must be regenerated whenever the qualify run adds templates (part of F2's commit).

## F. LLM queue (runs on its own, one model process)

- [x] **F1 No client timeout.** The GPU is shared with another job, so the model is slow, and that is accepted
  (the user's decision, 2026-10-11): the qualify client has no request timeout and retries 502/503/504 for as long as
  it takes (`ChatClient(timeout=None, max_attempts=None)`); before, it gave up after 7 retries. The 504 itself comes
  from the nginx gateway in front of llm, which a client cannot lift. Tests: unbounded retries past the default
  limit; the default client still gives up. The service was restarted on the new code.
- [x] **F2** (2026-10-12, the user: carry the finished RedHat packages on without waiting for the queue's end.) Each
  loop tick: `package_e2e_worklist` (re-route) → `export_agent_config_projection --write` → `package_e2e --family
  redhat --routes wizard,rule-template,rule-codec` (no `--redo`: only packages without a result for their route) →
  `template_shipped_fidelity` (incremental) → `repair_from_shipped --only <new differs>` → `explain_differs --only …`
  → `sync_value_sets --write` → commit after check_catalog_fit + tests. First tick (2026-10-12): 185 RedHat packages
  newly routed (unrouted 587 → 402), all 190 pod runs `pass-unverified` (configured and re-read, no failure, no
  verified checker); 345 units measured (11 identical, 84 same-settings, 145 differs); 11 of 88 repaired; openbox-redhat
  rebuilt (identical); every differing unit has a reason.
  **Tick 3 (2026-10-14, the queue stopped by the user after the RedHat remainder and the Debian worklist pass):**
  Debian unrouted 758 → 90, RedHat 219. Pods for 737 packages; then two policy changes, because the first numbers
  were not facts: (a) the validator miner had written 850 Debian checkers nobody ran — 52 "failures" were the
  checkers' — so runners now use only checkers whose `source` starts with "verified", and `probe_checkers --mined`
  probed all mined ones (counter-probe with a broken file first, shipped file must pass, no file written under
  /etc, /var/lib, /var/spool, /srv, /opt, /root, /home): 20 verified, 134 rejected with the reason, 11 infra-error;
  `apt-mirror <file>` runs the mirror and was rejected by hand (the side-effect watch now covers /var/spool);
  (b) the queue's worklist pass had regenerated 17 already-repaired templates — qualify now leaves catalog templates
  and meta `hand`/`repaired` alone (test). The six genuine checker findings were template or catalog defects, all
  fixed and passing in the pod: dictd (`port:` outside its section → hand template over the shipped file),
  carbon-c-relay (a cluster without its type at defaults → defaults = the shipped commented file), kea-dhcp6 (SQL and
  reclaim keys in the memfile lease map, loggers outside Dhcp6 with the string default `"["`), kea-dhcp-ddns
  (loggers outside DhcpDdns), cubemap (`error_log_type` — a parameter of `error_log` — in the directive catalog),
  the five daemon-failed ones (mined daemon commands, now set aside) pass. kea's EL files log to a file:
  `kea-dhcp6-server-redhat` and `kea-dhcp-ddns-server-redhat` — all four kea units same-settings. tinyproxy: the
  queue had written tinyproxy.conf directives into the shell environment file /etc/default/tinyproxy (passed only
  because no checker exists) → hand template over the shipped file (same-settings).
  That made a class visible: **a template of ANOTHER file**. Measured over the 1209 differing units, 375 share no
  setting name with their file; restricted to files that have settings and were fetched at the path itself, 149.
  `explain_differs` now records `wrong-file` first; the template index withdraws such a binding per family (named,
  verdict `wrong-file`), and keeps the reason while the template's hash is unchanged so the next index build does
  not re-bind it. 145 withdrawn after three rounds (74 → 82 → 85 Debian, 53 → 58 → 60 RedHat — each withdrawal
  frees the path for the next-ranked template, which the following tick measures). Catalog bindings are exempt:
  **16 catalog roles were writing another file** (ppp/options got a logrotate rule, charon.conf an AppArmor
  profile, kresd.conf YAML, …) and were rebuilt from the shipped file — all 16 identical; pods 15 pass-unverified +
  insserv install-failed (as before); role path kresd.conf, mptcpd.conf, snapserver compliant, ferm shipped-fails
  (its shipped file fails too, no journal).
  **Tick 4 (2026-10-15, no GPU — the queue stopped by the user at [174/218] of the RedHat worklist pass):** the
  supervisor had queued the unrouted worklist for Debian only (fixed, ebc4cba41). Re-routed: RedHat unrouted
  219 → 197. Pods for the 23 newly routed packages: 19 pass-unverified, 4 render-failed — all four routing defects,
  none a template's: chkconfig and initscripts were routed to /etc/init.d, a DIRECTORY (the worklist now applies the
  index's plausible_target rule: both are no-config "ships only a directory", test); hirte and hirte-agent: `dnf
  install hirte` resolves to bluechi-controller 1.3.0 (Obsoletes: hirte < 0.6.0), so the measured
  /etc/hirte/hirte.conf of hirte 0.4.0 is never on a host. Measured for the whole universe
  (`tools/rpm_replacements`, one repoquery + rpm labelCompare in the fetch container): 3 of 1902 RedHat packages are
  replaced (hirte, hirte-agent → bluechi, pki-servlet-engine → tomcat); the worklist routes them `replaced`, naming
  the replacement, and the runner records that instead of the stale result (test). The runner also had a defect:
  it skipped a package with ANY result, even one of an older route — 29 packages' current route had never run
  (11 Debian ones once unrouted, since routed to a template). A result now counts only for its own route; the 29
  ran: 22 pass-unverified, 4 no-config-confirmed, 3 install-failed (rdnssd → resolvconf in a container,
  debian-edu-config needs a Debian Edu site, sympa's postinst needs a database and rsyslog). Stage 5: 10 new units (6
  same-settings, 4 differs, each with a reason; the chain improved none). One differing unit was a template over
  elrepo's Secure Boot key (.der): the index now refuses key material and trust anchors (`unsuitable_target`, 8
  bindings: .der/.pem/.asc/trusted.gpg.d), test. Watch it, don't drive it: RedHat universe (1100), then the Debian worklist (758 unrouted), then the
  validator miner. Commit its output after the fit and parity tests pass. Done when `--check-only` reports 0 pending
  for both families and the worklist pass.

  **Done 2026-10-16.** The queue ran on (the man7.org hang that kept every request from the LLM is fixed,
  36a3107d5): the RedHat worklist pass finished — 43 packages, almost all fonts and fontpath entries with nothing to
  configure; no new routes. `qualify_packages --check-only`: 0 pending for both families, and the worklist pass 0
  pending for both. The e2e table has no `pending` left — every package of both families has a result or a named
  reason (the runner now also writes the `unrouted` row for packages that never had a route: 283 of them stood as
  "pending"). Final table (`package_e2e --check-only`):
  Debian — wizard 417 pass-unverified / 36 pass / 17 install-only / 1 install-failed; rule-template 742 / 15 /
  11 install-failed / 2 render-failed; rule-codec 613 / 5 / 5 install-failed; no-config 6585 confirmed / 16
  install-failed; unrouted 90.
  RedHat — wizard 30 pass-unverified / 23 pass / 9 install-only; rule-template 664 / 2 install-failed; rule-codec
  931 / 1 pass / 4 install-failed; no-config 38 confirmed; replaced 3; unrouted 197.
  The validator miner keeps running on its own (3059 packages); its checkers count only after `probe_checkers
  --mined` (a checker that never exits is now `rejected`, 7f68aaa66). What this does NOT prove is listed in the
  CHANGELOG's "what is still missing": most passes are unverified (no checker), and 287 packages are unrouted.

## G. Named gaps in the catalog (from the docs' "what is still missing")

- [x] **G1 kea**: a role per daemon (kea-dhcp4-server) with required `subnet4`, as isc-dhcp-server has. Today it is
  install-only. Done 2026-10-11: the `kea` role is the DHCPv4 server (Debian kea-dhcp4-server /
  kea-dhcp4-server.service, EL kea / kea-dhcp4.service, both /etc/kea/kea-dhcp4.conf). Hand template from the shipped
  file: subnet4 (required: subnet, pool, routers, DNS), interfaces and the lease timers are fields, the rest verbatim;
  `kea-redhat` the same over the RPM's file. Defaults identical to the shipped file on both families;
  `kea-dhcp4 -t` verified against the shipped file and added as checker; the role compliant on both families with a
  test subnet, and the checker accepts the written file.
- [x] **G2 File-shaped site values**: swift rings, ctdb nodes, chasquid's domain directory, mysqld-exporter's .my.cnf,
  certificates. This needs a design first (a second file per role, or an upload).
  Design chosen and built (2026-10-12): a role's family branch declares `files` (path, field, mode, owner, group,
  secret); each is a multi-line form field (masked when secret, family-tagged) plus a `copy` step after the render
  (wizard_seed._with_files). **ctdb** (nodes) and **prometheus-mysqld-exporter** (.my.cnf) now compliant. Not done,
  with the reason: swift rings are binary files BUILT by swift-ring-builder (a command, not a file value);
  chasquid's directory name is the domain itself (a path made from a value — needs path templating in the step);
  certificates/keys belong in the password store by reference, not in a deployment's parameters; krb5-kdc likewise
  (realm + master password).
- [x] **G3 AlmaLinux install-only roles** (done: rsyslog, mysql-server, opendkim configured; auditd restart fixed in the agent; krb5-kdc → G2-style design; iscsi-target: container limit): rsyslog, mysql-server, opendkim (domain name), krb5-kdc, iscsi-target,
  auditd. Verify each EL file and unit, as done for squid, opendmarc and opendkim.
  2026-10-11: **rsyslog** and **mysql-server** now configure /etc/rsyslog.conf (rsyslog.service) and
  /etc/my.cnf.d/mysql-server.cnf (mysqld.service), from the RPMs, with EL templates built by
  `template_from_shipped --names-from` — both compliant on EL. **opendkim**: opendkim-default-keygen skips the key
  on a host without a domain name (rc 0, measured) — the init now runs opendkim-genkey (opendkim-tools) directly;
  compliant on EL. **auditd**: RefuseManualStop=yes refuses `systemctl restart` on EVERY host; the agent now uses
  the package's legacy restart action (`service auditd restart`) and otherwise names the refusal (test; agent build
  after 0.57.85). Not verifiable in a container (auditd: "Error setting audit daemon pid (Operation not permitted)").
  Open: **krb5-kdc** needs a realm and a KDC database (a role design: required realm, init kdb5_util create);
  **iscsi-target** needs sys-kernel-config.mount (masked in a container). krb5-kdc waits for a design like G2: its
  database needs a realm and a master password, a role init cannot read role values, and the password belongs in
  the password store, not in a template.
- [x] **G4 java-latest**: version-pinned paths; resolve the version on the host. 3 render-failed on the pod path.
  The registry pins paths to a release (java-latest's java-25 while the mirror ships 27; java-21 paths carry the full
  NVR, so every patch update lost the codec on a host). The agent's codec lookup now has a versionless step (every
  digit run alike, only when that names one codec; test), and the pod e2e resolves a recorded path to the installed
  release's file the same way. Agent 0.57.85.
- [x] **G5 Family field asymmetry** (decided and done: the role form is the union of its family templates, and EL templates are built from the RPM file with the role's field names — steps (1) and (2) below): shown and refused today. Decide whether EL templates should gain the Debian
  fields that are valid for EL too (squid: 3 fields vs 207).
  Done for **haproxy** (C1): `haproxy-redhat` uses the role's field names for the directives both files have
  (maxconn, user, group, mode, log, timeouts, bind port, backend name, balance, servers, the TLS block); its defaults
  are the RPM's values and render the RPM's haproxy.cfg byte for byte (E1 tool: identical); the role is compliant on
  both families; the wizard test passes on EL.
  Counted (2026-10-11): 26 roles render another template on EL; **9 share no field with it** (clamav, freeradius,
  exim4, bind9, lighttpd, collectd, ntpsec, nftables, caddy) and squid lacks 205 of 207 — on an EL host the wizard
  greys out (nearly) everything, so these roles are not configurable there. Two steps: (1) systemic — on a host whose
  family is known, the wizard offers the fields of the template that will actually be written there (the EL
  template's own fields), not the Debian role's fields greyed out; (2) per role, as for haproxy — the directives both
  files have get the role's field names, because a deployment over mixed families has one set of values.
  **Step (2), the generic tool:** `template_from_shipped --names-from <role template>` builds a family template
  from the RPM's file and names each directive the way the role's template does (`myhostname` → the role's
  `hostname`), lending type/value set/description but keeping the file's own default; a directive the role names
  that the file only shows as commented examples is anchored at the first example; one ACTIVE line among commented
  examples is the field. First use: **postfix on AlmaLinux had no family template** and wrote Debian's main.cf
  (32 RPM settings gone); `postfix-redhat` now reproduces the RPM's main.cf byte for byte, shares hostname,
  domain, relayhost, mynetworks, inet_interfaces with the role, the role is compliant on EL and `postfix check`
  accepts the file. **Six more** built the same way where it adds shared fields and loses no EL field:
  freeradius (shared 0 → 34), bind9 (0 → 7), vsftpd (5 → 11), proftpd (2 → 9), cups (6 → 8), redis (9 → 10); each
  reproduces the RPM's file (bind9: same settings, the others byte for byte) and the six roles are compliant on EL
  (bind9, cups, proftpd also pass their checker). The builder's three render failures were its own defects, now
  fixed: the file's own `{%`/`{{` (php-fpm's `%{%Y-%m-%d}t`) are written as literals, a value continued with `\`
  (exim) is not a field, and a directive whose name is an engine keyword (collectd `In`, `Include`) gets
  `_directive`. exim4-redhat rebuilt (differs → identical, EL fields 22 → 41, role compliant on EL). Not taken:
  ntpsec, collectd, php-fpm — the rebuild would lose EL fields.
  **Step (1) done:** the role's parameters are the union of its templates — a family template's own fields join,
  tagged `families: [...]`, never `required` for the role as a whole (`wizard_seed._add_family_fields`); the wizard
  greys out a field whose `families` exclude the host's family, with the reason; the engine refuses a value SET for
  such a field on a host of another family (`_family_only`), naming it, instead of letting it vanish. Seeded:
  bind9 +15 EL fields, haproxy +20, clamav +4, squid +1. Tests: seed over the real catalog, engine refusal; the
  affected roles stay compliant on both families; the wizard Playwright blocks pass.

## I. Found on the way (not in the original plan)

- [x] **I1 Housekeeping's process prune died on a FK race** (`metrics_raw_series_id_fkey`, twice in 40 min): its
  NOT EXISTS guard could not see a point the poller inserted while the statement ran. Phase 2 now locks the series
  rows with `FOR UPDATE SKIP LOCKED` (a series being written is left for a later run), and a run no longer re-selects
  the series it skipped (it spun to its batch cap). Test with two sessions; it fails without SKIP LOCKED.
  **Data loss caused by me while testing it:** a probe called the prune with `now + 1h`, which made every live
  process series look stale — 1208 process series younger than a day and their points (process_cpu_percent,
  process_rss_bytes) were deleted from the one database. Live processes recreate their series on the next poll; up to
  a day of per-process history is gone. Rule kept: never a shifted clock against the shared database.

- [x] **I2 The metric-series orphan sweep died on the same FK race** (2026-10-15, right after a reboot, while the
  poller caught up): a brand-new series has no committed point while the poller's first insert is in flight, so
  the sweep's NOT EXISTS judged it orphaned and the delete hit `metrics_raw_series_id_fkey`. Same fix as I1 — the
  candidates are locked `FOR UPDATE OF s SKIP LOCKED` (a series being written is left for a later run) and
  re-checked; the sweep is its own function (`sweep_orphan_series`). Two-session test; without the lock it waits
  on the poller and times out (verified both ways). Found by the full suite against the restarted stack.

## H. Records, after every block

- [x] CHANGELOG entry with the measurement; `docs/package-config-e2e.md` tables; CODE_CARD for new interfaces;
  memory for lessons that transfer. Tick the item here in the same commit. (Kept up per block; CHANGELOG has a "what is
  still missing" section for this work, CODE_CARD the new interfaces, memory the transferable lessons.)

## Order

A → B → C → D → E1 → E2 → E3 → E4 → G (G2 waits for a design). F2 runs alongside all of it.
