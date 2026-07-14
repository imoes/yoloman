# Class-B config templates

Each subdirectory is a Class-B config: a config file with no clean bidirectional
codec, owned instead as a Jinja2 `template.j2` + a `schema.json` (variables) +
`sample.json` (concrete values). The agent's `template_render` module (gonja,
pure Go) renders them. `internal/modules/template_render_test.go` renders every
template here against its `sample.json` on `go test`, so a broken template (e.g.
a Django/pongo2-ism) fails CI, not a live host.

Templates come from two sources:
- **LLM-bootstrapped** from a real example config (+ optional man page) via
  `bossman/scripts/bootstrap_config_template.py` (qwen79b): nginx, apache2,
  redis, haproxy, postfix, hosts, logrotate, crontab, anacrontab, smartd.
- **Hand-authored** where no local example exists (Proxmox/KVM, from the
  product docs): proxmox-vm, libvirt-domain, corosync, storage-cfg.

## "none"-classified configs and their coverage

`config_codecs.json` classifies 22 config files as codec `none` (no structured
codec — Class-B is the only option). Coverage of that set:

**Templated** (server config an admin generates declaratively): hosts,
logrotate.conf, crontab, anacrontab, smartd.conf, corosync.conf, storage.cfg.

**Intentionally NOT templated** (not declarative server config — a template adds
no value or is unsafe to machine-generate):
- `sudoers` — security-critical bespoke grammar; must go through visudo
  validation, not a rendered file. (Candidate for a dedicated, validated module.)
- `apparmor.d` — MAC profile DSL, too complex/risky to round-trip generically.
- `rsyslog.conf`, `hdparm.conf` — bespoke rule/device DSLs; niche, low demand.
- `user.cfg` (Proxmox ACL) — sensitive, managed via pvesh/API, not file render.
- `apt.conf` — absent here and effectively a C-like keyvalue tree (revisit as a
  codec, not a template).
- `Xsession`, `update-motd`, `gdbinit`, `gimprc`, `core`, `magic`, `issue`,
  `ucf.conf`, `client.conf` — login scripts, tool databases, static banners, or
  app configs, not server-management surface.

Add a skipped one later by running the bootstrap script (or hand-authoring) and
dropping a `<name>/` dir here — the render test picks it up automatically.
