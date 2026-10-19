# Every package, configured and tested — the package e2e

**Question.** Is every available package configurable by a rule or by the wizard — on Debian *and* on RedHat — and
does the configuration the product writes actually work? Until 2026-10-09 the answer was asserted from the catalog:
templates, codecs and enums existed for thousands of packages, but no package had ever been installed, configured and
judged by its own checker.

**Answer, measured.** See [Results](#results). Every package is classified into exactly one route, every route is
exercised in a real container, and every outcome is one of a fixed set of named states with its evidence.

## What "configurable" means

Each (family, package) gets exactly one **route** — `bossman/bossman/tools/package_e2e_worklist.py`,
`configs/package_e2e_worklist.json`:

| route | meaning |
|---|---|
| `wizard` | a catalog role offers the package on this family → the `install-<role>` runbook (preview / apply) |
| `rule-template` | its primary `/etc` file is freeform and a template renders exactly that file (family-matched) |
| `rule-codec` | its primary `/etc` file is parseable (keyvalue / ini / json / yaml / xml / …) → per-key `config` resource |
| `no-config` | it ships no configuration file under `/etc` (nothing, or only executed scripts) |
| `unrouted` | it ships a configuration file, but no route reaches it — **the finding the list exists for** |

The files are **measured, not guessed**: Debian's from the trixie archive's `Contents` index (the path → package map of
the whole archive), RedHat's from the repos' `filelists.xml` (BaseOS, AppStream, CRB, EPEL). Only 2164 of 8555 Debian
packages ship a non-noise file under `/etc` at all. The file tested is the file the pipeline processed (a template's
recorded target, a codec entry naming the package) before any fresh pick; executed files (init, runit, cron run-parts,
hook directories, `*.sh`) are never a config route.

## How it is tested

Three independent paths, each closer to the product than the last:

1. **Agent in a pod** — `tools/package_e2e.py` + `deploy/test-images/e2e-one.py`. One **fresh** pod per package
   (Debian trixie / AlmaLinux 9 + EPEL images, `deploy/test-images/`), so nothing one package installs can make the
   next pass. Install → configure with the **agent's own modules** (`agentic-mcpd run-module template_render | config`,
   the Go code a Bossman apply runs) with the template's defaults *and* one variant derived from the schema (another
   enum value, a flipped bool, a number in range — never a guessed free-text value) → the package's own checker →
   a 10-second foreground start. The result is one line read from the pod log; no `kubectl exec`.
2. **The Bossman path** — `tools/package_e2e_bossman.py`. Every catalog role through the **real role-deployment API**
   (preview → create → reconcile, the calls the Roles & Features page makes) onto a **fresh systemd host** per role:
   the agent runs as the packaged `yoloman-agent.service`, enrolls with Bossman, and the wizard's service step meets a
   real init. The configured file is read back (`slurp`) and checked, so "compliant" is verified, not believed.
3. **The UI** — Playwright (`bossman-ui/e2e/`): a consistency crawler over every route plus scenarios for Kubernetes,
   package installation, role management and the deployment pipeline (see [UI](#ui)).

Outcomes are exhaustive — `pass` · `pass-unverified` (configured, no checker known, reason given) · `install-failed` ·
`target-missing` · `render-failed` · `validate-failed` · `daemon-failed` · `install-only` · `no-config-confirmed` ·
`no-config-refuted` · `infra-error` (a fact about the test, retried) — each with the command, exit code and output.

### Running it

```bash
deploy/test-images/build.sh                      # images (content-hash tags → ~/.local/state/agentic-batches/pkg-e2e-images.json)
minikube -p bossman-dev mount configs:/configs   # keep running: pods read templates from here
deploy/test-images/agent-hosts.sh up             # long-lived enrolled hosts for the Bossman path and Playwright
docker network connect bossman-dev agentic-mcp-bossman-1   # after EVERY bossman container recreate
cd bossman
.venv-host/bin/python -m bossman.tools.package_e2e_worklist [--refresh-debian-paths]
.venv-host/bin/python -m bossman.tools.package_e2e --check-only | --parallel 4
.venv-host/bin/python -m bossman.tools.package_e2e_bossman --check-only | --parallel 3 [--keep]
cd ../bossman-ui && npx playwright test
```

## What the test found — and what was fixed

| defect | how it showed | fix |
|---|---|---|
| the agent stripped the trailing newline of every rendered file | haproxy: "Missing LF on last line" | `template_render` keeps the template's final newline (agent 0.57.75) |
| the wizard rendered the **Debian** template on every family | Debian's nginx.conf on AlmaLinux | the family's own template for the destination file wins, with its own defaults inline |
| a failed check (`nginx -t` rc=1) counted as a change | nginx restarted with a broken file and stayed down | a non-zero exit fails `command`/`shell` (Ansible's semantics) |
| detection ran the validate command in check mode | every role with a check stayed noncompliant, no reason | commands are not part of detection; drift names its steps |
| generated install runbooks used NestedText's `${…}` | ~436 roles ran `apt-get install -y ${_packages}` | `{{ … }}`, and a test forbids `${` |
| mechanical template repairs ran for 14 templates only | 606 of 709 templates did not reproduce the shipped file | the repair chain runs after every parametrization |
| a role was "compliant" with nothing configured | samba wrote a ufw profile over smb.conf; php-fpm wrote into a directory named `*` and read the same path back | the right templates; the engine refuses a pattern destination |
| a RedHat host got the role's Debian defaults | php-fpm on AlmaLinux: `user = www-data` | on a family template, a value equal to the role default yields to the template's own |
| the role form offered fields that changed nothing | 94 fields in 8 roles (samba's `workgroup`) | the template's schema defines the fields, the playbook only defaults |
| config files lacked their last newline | nftables: "unexpected junk" on the last comment line; 5246/5754 templates | final LF decided on the rendered text; qualify keeps it |
| the agent rendered `true \| int` as 0 | acmesh `AUTO_RENEW="0"` for auto_renew=true | `int`/`float` give Python's answer for booleans (agent 0.57.78) |
| form defaults did not match the field type | "role parameter 'log_level' must be number" at preview | 519 fields normalized; qualify normalizes every package |
| masked units, finished oneshots, static units | hostapd never started; chkboot never compliant | `masked: false`; a successful oneshot is started; static counts as enabled (agent 0.57.77) |
| two UI controls could never be used | Roles & Features "Preview", Disk images "Save grow policy" | conditions re-evaluate |

## Results

*As of 2026-10-10 18:40. The role results are a final, consistent run over every catalog role. The routes still
move: the LLM queue qualifies the rest of the RedHat universe (1155 of 1902 packages to go at the time of
writing), then the Debian `unrouted` packages and the validator catalog — one model request at a time.*

### Routes (configs/package_e2e_worklist.json)

| family | packages | wizard | rule-template | rule-codec | no-config | unrouted |
|---|---|---|---|---|---|---|
| Debian 13 | 8555 | 470 | 128 | 600 | 6599 | 758 |
| AlmaLinux 9 | 1902 | 61 | 294 | 924 | 36 | 587 |

RedHat `unrouted` was 836 before the RedHat qualify pass started; rule-template rose from 48 to 294 so far.

### Agent in a pod (configs/package_e2e_results.jsonl)

- **no-config:** Debian 6583 confirmed (16 do not install), RedHat 36 confirmed. The first run reported 256
  "refuted"; every one was an init/profile/cron/hook script the worklist rightly does not count — the pod now
  applies the worklist's own rule.
- **configured (re-run 2026-10-11, agent 0.57.84/0.57.85, installs through the agent, the family template the
  product renders):**

  | route | family | pass | pass-unverified | install-only | install-failed | render-failed | validate-failed |
  |---|---|---|---|---|---|---|---|
  | wizard | Debian | 24 | 428 | 17 | 1 | 0 | 0 |
  | wizard | AlmaLinux | 22 | 30 | 9 | 0 | 0 | 0 |
  | rule-template | Debian | 0 | 126 | 0 | 2 | 0 | 0 |
  | rule-template | AlmaLinux | 0 | 294 | 0 | 0 | 0 | 0 |
  | rule-codec | Debian | 2 | 592 | 0 | 6 | 0 | 0 |
  | rule-codec | AlmaLinux | 1 | 919 | 0 | 4 | 0 | 0 |

  `pass` = the package's own checker (24 verified checkers, `configs/package_validators.json`) accepted the written
  file, defaults and a variant; `pass-unverified` = written and re-read, no verified checker for the package.
  **Every failure has a named cause:** init-system conflicts (insserv, openrc, elogind — they replace systemd's
  pieces); the pod's /etc/resolv.conf is a mount, so resolvconf's postinst cannot replace it (whereami, ifupdown-ng,
  rdnssd); site configuration the test host lacks (sympa: /etc/mailname; debian-edu-router: its router setup);
  hylafax-server's postinst asks "Area code []?" forever (stopped by the agent's output cap); EPEL gaps
  (copr-builder: nothing provides libdnf5) and timeouts of large KDE stacks (kwebkitpart, plasma-welcome);
  asterisk-dahdi's %pre runs `usermod -a -G dahdi asterisk` before anything creates the asterisk user (EPEL packaging). Found and fixed by this run: the pod rendered the role's
  Debian template on AlmaLinux (squid refused Debian's `to_linklocal` ACL) — it now renders the family template
  the engine renders; postfix-redhat offered `html_directory` as yes/no (`yes` is refused); containerd ran on a
  repair that was later reverted; java-latest's recorded path names java-25/26 while the mirror ships 27 — the
  agent's codec lookup and the pod now resolve the installed release's file (all three pass).

### Stage 5: do the defaults reproduce the shipped file? (configs/template_shipped_fidelity.json)

Every template a request can reach, per family and file, rendered with its own defaults by the agent's engine and
compared with the file the package ships (`bossman/bossman/tools/template_shipped_fidelity.py`, 2026-10-12):

| units | family | identical | same-settings | differs | no-shipped-file | no-package | does-not-render | no-target | total |
|---|---|---|---|---|---|---|---|---|---|
| all reachable units | Debian | 70 | 298 | 623 | 235 | 62 | 2 | 16 | 1306 |
| all reachable units | AlmaLinux | 41 | 140 | 541 | 78 | 793 | 2 | 0 | 1595 |
| catalog-role units | Debian | 59 | 172 | 180 | 21 | 4 | 0 | 0 | 436 |
| catalog-role units | AlmaLinux | 19 | 9 | 12 | 1 | 0 | 0 | 0 | 41 |

`same-settings` = only comments or spacing differ. `no-shipped-file` = the package does not ship that path (written
by a postinst, or another package's file); `no-package` = no candidate package downloadable for that family (mostly
EL index entries for Debian-only packages). The two `does-not-render` are server.yaml's deliberate `| mandatory`
(site values). Repairs: `repair_from_shipped` (mechanical chain, kept only when every unit of the template gets closer,
the sample renders, and — for catalog roles — the role still works) and rebuilds from the shipped file with the role's
own field names (`template_from_shipped --names-from`).

### Through Bossman (configs/package_e2e_bossman_results.jsonl)

298 catalog roles, each on a fresh systemd host through the role-deployment API, read back and checked, and
`compliant` only if the unit is still running 10 s after the verification (else `unstable`):

| | Debian 13 | AlmaLinux 9 | total |
|---|---|---|---|
| **compliant** | 185 | 53 | **238** |
| not available on the family (named, with the catalog's reason) | 3 | 7 | 10 |
| merged into another role (same daemon, same file: mpd, ntp, redis-server, openssh-server, mariadb-server) | 5 | 3 | 8 |
| the daemon fails — with the package's own file too, or for a peer/site value the test host lacks (cause below) | 38 | 4 | 42 |
| open | | | 0 |

**2026-10-11: the count went DOWN, from 249 to 238, and is truer for it.** 44 Debian roles (and 5 on AlmaLinux) named
no unit: they wrote their file and restarted nothing, and the e2e — with no unit to watch — counted them compliant on
the file alone. With the unit named from what each package ships (`configs/debian_package_units.json`), their daemons
now start with the role's file, and eleven did not: an sshd_config whose defaults were empty values (a lockout on a
real host), a mosquitto/prometheus/keepalived template written for the wrong file, a sssd.conf with the wrong mode and
no domain, mariadb's invented template. Those are fixed (sshd, mosquitto, prometheus, keepalived and sssd compliant,
the last two with required site values) or named (krb5-kdc's realm database, bacula-director's PostgreSQL catalog,
apparmor/auditd in a container). Five roles were the same daemon twice and are merged. The DHCP server now runs on
both families.

From 76 on the first run (2026-10-09) to 175 on the morning of 2026-10-10 to 249 (248 after `mpd` was merged into `mpd.conf`, 249 again with iodined). The stability check turned two former
"compliant" into fixes (mopidy, pygopherd — their daemons died seconds after starting). No role is open: each of the
48 that do not reach `compliant` is either unavailable on its family or fails with the package's own file, with a cause.
The last four open ones were resolved on 2026-10-10: cups is compliant (a cupsd.conf template parametrized from
`/usr/share/cups/cupsd.conf.default`, byte-identical with its defaults, `cupsd -t` accepts defaults and variant);
svxlink-server needs a sound card (read from its own log file, which the baseline now tails); myproxy-server needs a
host certificate; swift-object-expirer a swift ring.

Reading the ROLE's error next to the baseline's cause found four template defects the cause had hidden (the role
failed for its own reason before reaching the site value): hostapd (keys hostapd does not know, WPS on), hdapsd
(INI written into a libconfig file — "line 5: syntax error"), gammu-smsdrc (no `service`, invented key names) and
miredo (the role wrote `/etc/default/miredo`, which no unit reads; the daemon reads `/etc/miredo.conf`). Each is
rebuilt from the shipped file and now stops only at what the test host lacks — a Wi-Fi card, an accelerometer, a
modem, external DNS. rbootd needed `/var/lib/rbootd`, which its package does not create.

rsync and radicale configured `/etc/default/<name>`, which their systemd units never read. rsync's unit starts only
when `/etc/rsyncd.conf` exists — no package ships it, so the template is the package's own example
(`/usr/share/doc/rsync/examples/rsyncd.conf`, modules as a list); radicale reads `/etc/radicale/config` (77 fields,
generated mechanically from the shipped file, enums from its own "Value: a | b" comments) and needs its collections
directory handed to the `radicale` user once. Both are compliant.

For every role whose service did not run, the **baseline** pass installs the package on another fresh host and
starts the unit with the configuration the package *ships* — no role, no template:

- runs → `template`: the role's configuration is what breaks it (44 roles; regenerated from the shipped file by
  `qualify_packages --repair`, or fixed by hand);
- fails too → `shipped-fails`, with a **cause** read from the unit's journal (`package_e2e_bossman --classify`).

"The container" was the first guess for all of them. The journals say it is the cause for five:

| cause | roles | what it means |
|---|---|---|
| `needs-site-config` | 17 — chasquid, ctdb, fapolicyd, firehol, myproxy ×2, mysqld-exporter, rbootd (boot images), swift ×5, thinkfan; RH isc-dhcp-server, krb5-kdc, openvpn | the shipped file lacks values every site must supply (a realm, a subnet, an interface, a ring file, a server type). The role exists to supply them — when it fails too, its wizard lacks a required field |
| `needs-internet` | 1 — miredo | its shipped file names a Teredo server by hostname; the isolated test host cannot resolve it (a limit of the test — a variant with an address passes `miredo-checkconf`) |
| `hardware` | 6 — comitup, gammu-smsd ×2, hdapsd, mbpfan, svxlink (no sound card — from its own log file) | the daemon drives hardware (Wi-Fi, a modem, laptop sensors) the test host does not have |
| `container` | 6 — haveged, systemd-timesyncd (`ConditionVirtualization=!container`), espeakup (modprobe), ferm (ip6tables-restore), dphys-swapfile (swapon); RH auditd | refuses containers, or needs a kernel facility the container does not grant |
| `needs-peer` | 5 — corosync-qdevice, mythtv-status, postfix-exporter, zoneminder (its database), biboumi (its XMPP server — reached only after its role asked for hostname and password, its invented `log_file` default was removed and its database directory created) | it talks to a cluster, a backend or the daemon it monitors |
| `masked` | 1 — hostapd (iodined was the other: its role now asks for the tunnel address, domain and password, and is compliant with them) | Debian installs the unit masked; every restart was refused — fixed (below) |
| `oneshot-finished` | 1 — chkboot | a oneshot that ran and finished; "not running" is its success, yet `started` was a change forever — fixed (below) |
| `service-user-missing` | 0 — osmo-hlr, osmo-stp were: the unit's `User=osmocom` is created by no trixie package; the role creates it once, and both templates (VTY syntax lost its indentation; osmo-stp invented) were rebuilt from the shipped files — compliant since |
| `missing-binary` | 0 — dns-flood-detector, linuxptp were: dns-flood-detector's unit starts `/usr/sbin/…` (the package ships `/usr/bin/…`) and is Type=notify while its shipped options fork with -d — a self-retiring drop-in fixes both, compliant since; linuxptp's promoted unit was timemaster — wrong unit, fixed (below) |
| `shipped-config-invalid` | 0 — sniproxy was: Debian builds it without libudns and its shipped file names `fallback localhost:8080`, a hostname, so the binary refuses the whole file; the role's new sniproxy.conf template writes an address there — compliant since |
| `needs-init` | 1 — RH postgresql | EL's postinst does not run `initdb` (Debian's does) — fixed (below) |
| `crash` · `no-journal` | 1 · 2 — direvent: SEGV when no watcher is declared, and the shipped file declares none; a watcher (path, event, command) is the site's decision — the role's `watchers` list now writes real ones (its old fields all sat in comments) · connman (the host stops answering), RH iscsi-target | |
| `dependency` | 0 — mandos was one: `Requisite=avahi-daemon.service`, and installing avahi does not start it; the role starts it first, compliant since | |
| `unclassified` | 0 — RH freeradius was one: its EAP certificates are created once (`init`), compliant since |

Found on the way and fixed: the Debian test image lacked `adduser` (priority *important*, present on every
installed system) — postinsts skipped `adduser --system` and units failed with 217/USER
(prometheus-exporter-exporter runs since); catalog entries can name a family's one-time initialisation
(`families.<f>.init` → a runbook step right after the install; RH postgresql: `postgresql-setup --initdb`); linuxptp's
service is now empty (timemaster reads timemaster.conf, not ptp4l.conf); the agent's service module (0.57.77) lifts a
mask before a start (`masked: false`, sent by every role runbook), counts a oneshot that ran successfully as started
and a static/generated unit as enabled; a role deployment that fails on a service now quotes the daemon's journal line.

## UI

`bossman-ui/e2e/` — 136 tests against the running stack (UI :4201, Bossman :8123, enrolled test hosts in minikube).
Full run 2026-10-10 (afternoon): **128 passed, 2 failed, 4 skipped** (each skip names its reason in the spec, e.g. no Windows
test host on this instance); both failures were product defects, fixed and re-run green:

- `/change-proposals`: the proposal list became scrollable once proposals piled up and could not be reached by
  keyboard (axe `scrollable-region-focusable`).
- Resources → Packages rollback: the Generations tab showed "No recorded applies yet" while loading and when the
  request failed — loading, error and empty were one state. Now three named states, the error with its reason.

Re-run after the evening's backend changes (role forms built from the template's fields, catalog `enable` /
`init`, family defaults, pattern refusal): **132 passed, 0 failed, 4 skipped** (6.3 min). Re-run 2026-10-11 after the required-site-values wizard change (new scenario: iodined's Validate/Install greyed with the missing fields, enabled once filled): **133 passed, 0 failed, 5 skipped** (the fifth skip is that scenario on the AlmaLinux host, where iodined is not offered).

The suites: a consistency crawler over every route (console errors, failed API calls, axe critical/serious, no
horizontal scroll at 1280 and 390 px, every disabled control names its reason), and scenarios for Kubernetes
(application form → Deployment → pod running, scale, broken image with reason, rollback, delete with approval),
package installation per family (console install, Add-roles wizard with enum dropdowns, Resources → Packages plan /
apply / rollback), role management (editor, lint, versions, bindings with approval) and the SCCM-style deployment
pipeline (preview/create gating, four-eyes approval, pilot phase, drift correction, write gate).

### Test environment limit (resolved)

A systemd test host exited 255 within a second, printing nothing, when the node's root inotify instances ran out —
`fs.inotify.max_user_instances` (128) is shared by every root process of the host kernel, the minikube node's pods
included. Raised on 2026-10-10 to 1024 instances / 524288 watches (`/etc/sysctl.d/90-bossman-e2e-inotify.conf`);
a rerun of all non-compliant roles at parallel 4 had no host exit since. The runner still reports such an exit at
once ("host pod exited 255 … check the node's inotify instances").

## Values only the site has

A role whose daemon cannot start without a site value (a tunnel address, a realm, a passphrase) marks that template
field `required`. The wizard then refuses before anything is deployed: the form marks the field, Validate and Install
are greyed out with "Required settings are empty — <role>: <fields>", and the API answers the preview with 422 naming
every missing value. The e2e supplies test values from `configs/package_e2e_site_values.json` (documentation
addresses only) and records them per row (`site_values`); without them such a role ends `preview-refused`, which is
the product working. First role: iodined (compliant with values). Candidates named in the cause table below.

## What is still missing

Each item is a named gap with its reason, not a silent failure.

- **Roles that need site values the form does not ask for yet** (17, cause `needs-site-config`): the daemon refuses
  the package's own file too. The mechanism exists (a `required` field is asked for before deploying — iodined,
  biboumi use it); what is left needs more than a field: a FILE (swift rings ×5, ctdb nodes, chasquid's domain
  directory, mysqld-exporter's .my.cnf, fapolicyd rules, myproxy's host certificate, thinkfan's sensor list), a
  DECISION nobody should default (firehol's START_FIREHOL — enabling a firewall can lock a host out), boot images
  (rbootd), or, on AlmaLinux, a configuration the catalog does not model at all (krb5-kdc realm + KDC database,
  dhcpd subnet, openvpn server.conf + keys).
- **Container and hardware limits** (10): named per role in the baseline table above.
- **Renderer differences left**: gonja writes `1.0` as `1` and returns a boolean for `a or b` (19 templates,
  no catalog role); the parity test pins the catalog.
- **Template checks are not yet the package's checker**: the pipeline's invariants compare a template with the
  shipped file but do not run the daemon's parser — regenerated templates can still be structurally wrong
  (inspircd, oidentd were). The validator catalog (`mine_package_validators`, queued behind the LLM work) closes
  this; until then hand-fixed templates are curated and verified one by one.
- **Long-lived Playwright hosts** run an older agent (0.57.76); the Bossman-path runs use fresh hosts with the
  current one (0.57.80).
- **Template targets**: 22 catalog templates contradict the shipped file at their recorded path (witness pass);
  18 are being regenerated, the rest are named above.
- **Commented settings without a shipped file to ground them**: of the 182 reachable templates with placeholders on
  comment lines, 82 target a file no Debian package ships (written by a postinst, or not Debian's) — the activation
  needs the shipped line for its else branch, so they stay as they are; 26 have only ambiguous lines; 4 were
  rejected because activation would have changed their defaults' output.
- **Version-pinned paths** (resolved 2026-10-11): the registry records the release it measured (java-latest's
  java-25, java-21 paths with the full NVR); agent 0.57.85 matches the same path of another release when that names
  one codec, and the pod e2e resolves the installed file the same way — java-latest passes.
- **Packages the archive no longer has**: 11 versioned kernel packages (6.12.86) in the universe were superseded;
  their pod rows say `install-failed` with apt's own message.
