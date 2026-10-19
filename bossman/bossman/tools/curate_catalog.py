"""Make configs/package_catalog.json stop claiming things it never checked.

    .venv/bin/python scripts/curate_catalog.py --dry-run
    .venv/bin/python scripts/curate_catalog.py

Two curations, both fixing the same kind of defect — a generated field that asserts more than its
generator knew. Part A is about package NAMES per family, part B about the CONFIGURE action.

PART A — THE FAMILY BRANCHES. Two generators wrote the Debian package name into a `redhat` branch:
`classify_roles_features._catalog_entry` (`for fam in ("debian", "redhat")`) and
`build_package_catalog` step 1 (`{"debian": _fam(...), "redhat": _fam(...)}`). Neither had a
RedHat fact to write. Both are fixed, but the built catalog still carries their output: measured,
78 of 90 redhat branches were verbatim Debian copies, and ~15 of those are demonstrably wrong —
cron is `cronie`, slapd is `openldap-servers`, ufw does not exist on RHEL at all.

WHY A WRONG BRANCH IS WORSE THAN A MISSING ONE. `package_wizard` resolves a missing family by
falling back and SAYING SO (`family_match="fallback"`). A fabricated branch satisfies
`fams.get(family)`, so the fallback never runs and the wizard presents a guess as a curated fact.
Removing it does not lose information — it removes an assertion that was never information.

THE THREE OUTCOMES, and the evidence each requires:

  keep       The branch is already a real translation (apache2→httpd), OR it is identical to
             Debian but that identity is attested: either it is one of build_package_catalog's
             hand-written CORE entries, or the name appears in the RedHat half of
             configs/package_universe_real.json. 27 roles genuinely share a name across families
             (nginx, postfix, samba) — those are not copies, they are correct.
  curate     CORRECTIONS below supplies a checked RedHat branch. This table is knowledge, not a
             measurement, so it lives in ONE readable place instead of being spread through the
             generators. `source: "curated"` records that.
  drop       Neither attested nor in CORRECTIONS. The branch goes away and the entry becomes an
             honest "not curated for redhat".

PART B — THE CONFIGURE ACTION. `template` names the file the wizard's Configure step renders, and
the write path is `template_render`: WHOLE FILE, to `_dest = config_path`. So a template that does
not actually configure that file does not merely look odd — applying it REPLACES a live config.

Measured on the built catalog: 7 of 90 roles had a template that mentions not one of its own
schema's field names, because the batch harvested the wrong file out of the .deb:

    sshd         schema has 90 fields for /etc/ssh/sshd_config;  template.j2 is /etc/pam.d/sshd
    nfs.conf     20 fields for /etc/nfs.conf;                    template.j2 is an init script
    smb.conf     20 fields for /etc/samba/smb.conf;              template.j2 is an init script
    lvm.conf     19 fields;   template.j2 is the shipped EXAMPLE lvm.conf, no placeholders at all

Rendering the sshd one over sshd_config locks you out of the host. So: a template that references
none of its schema's fields is not a config template, and `template` is set to null — the UI
already has the honest branch for that ("No configuration template yet — installs with defaults,
no Configure step"), and an action that cannot succeed is not offered rather than offered and
regretted.

Four of those seven have a parsable codec for their path (sshd_config keyvalue, nfs.conf ini,
lvm.conf ini, oddjobd.conf xml), so they stay fully editable through the Configuration tab's
per-key merge — which is the safer editor anyway: it keeps foreign keys instead of overwriting the
file. smb.conf (codec=none) loses its Configure until its template is regenerated; sudo and
varnish have no config_path, so their Configure never did anything.

NOT fixed here, deliberately: 18 roles carry BOTH a template and a codec for the same path — two
editors for one file, the redundancy docs/config-model-consolidation calls out. Removing the
template for every codec'd path is the right end state but it is a decision, not a repair.

Idempotent: re-running finds the copies already gone and changes nothing.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

from bossman.tools._paths import configs_dir, repo_root

ROOT = repo_root(__file__)
CONFIGS = configs_dir(__file__)
CATALOG = CONFIGS / "package_catalog.json"
TEMPLATES_DIR = CONFIGS / "config_templates"
UNIVERSE = CONFIGS / "package_universe_real.json"

# One definition of "does this template configure its own file", not two that drift.
from bossman.tools.build_package_catalog import (  # noqa: E402
    CORE, TEMPLATE_ALIAS, _seed_packages, _template_configures, main_config_path,
)


#: The measured EL name list — "does a package with this name exist on Enterprise Linux", from
#: bossman.tools.record_el_package_names run in an almalinux:9 container over baseos/appstream/crb/epel.
EL_NAMES = CONFIGS / "package_names_el.json"


def _attested_el_names() -> tuple[set[str], list[str]]:
    """The names that count as attested on EL, and which records said so.

    THE UNION OF TWO RECORDS, because they answer two different questions and only one of them is about
    existence:

      package_names_el.json     does this NAME exist on EL — 33898 names, four real repos, unfiltered
      package_universe_real.json[redhat]  is this a configurable-service CANDIDATE — 1902, and the number
                                is small for two reasons: only BaseOS+AppStream, then a section/description
                                filter

    The second was the ONLY source, and it was being read as existence. Measured consequence: `sssd` (BaseOS)
    and `nginx` (AppStream) are both absent from it — `nginx` survived only via the builder's CORE table and
    `sssd`'s redhat branch was dropped, for the canonical RHEL identity client. Keeping it in the union costs
    nothing and preserves whatever it attested that a name list would not.

    A missing name list is reported, not defaulted: with no attestation at all only CORRECTIONS and CORE
    survive, which silently drops every other redhat branch. Nothing about that should be quiet.
    """
    names: set[str] = set()
    sources: list[str] = []
    try:
        el = json.loads(EL_NAMES.read_text())
        # THE DISTRIBUTION'S OWN REPOS ONLY — not EPEL, even though the record carries it.
        #
        # The question here is not "can this be installed on an EL box", it is "is this role's redhat branch
        # a real translation or a copied Debian guess". EPEL answers the first and not the second: measured,
        # EPEL ships `apt` and `ufw`, so counting it as attestation would KEEP exactly the copied branches
        # this pass exists to remove — `ufw` even has a curated UNAVAILABLE entry saying firewalld is the
        # supported front end there. A tool packaged in EPEL because someone wanted it is not the platform's
        # answer to what Debian's package does.
        found = {n for n, repos in (el.get("names") or {}).items()
                 if set(repos) - {"epel"}}
        if found:
            names |= found
            sources.append(f"{EL_NAMES.name} ({len(found)} names in baseos/appstream/crb; "
                           f"EPEL recorded but not attesting)")
    except (OSError, ValueError):
        print(f"! no {EL_NAMES.name} — run `python -m bossman.tools.record_el_package_names` in an EL "
              f"container; without it only the filtered service-candidate listing attests", file=sys.stderr)
    try:
        cand = set(json.loads(UNIVERSE.read_text()).get("redhat") or {})
        if cand:
            names |= cand
            sources.append(f"{UNIVERSE.name}[redhat] ({len(cand)} service candidates)")
    except (OSError, ValueError):
        print(f"! no {UNIVERSE.name}", file=sys.stderr)
    if not names:
        print("! NOTHING attests an EL package name — only CORRECTIONS/CORE branches will survive",
              file=sys.stderr)
    return names, sources


def _load_codecs() -> dict:
    """The codec registry — the witness main_config_path checks a claimed path against."""
    try:
        return json.loads((CONFIGS / "config_codecs.json").read_text())
    except (OSError, ValueError):
        return {}


def _core_keys() -> set[str]:
    """The hand-written CORE table in build_package_catalog. Those entries' redhat branches were
    decided by a person, so an identical name there is a decision, not a copy.

    READ AS DATA. This used to regex the builder's SOURCE FILE for `^    "name": {"label"` — which
    depended on the indentation of a dict literal in another file, and returned an empty set (silently
    curating away every CORE decision) the moment that file moved. Importing the dict cannot be wrong
    about what is in it."""
    return set(CORE)


#: Checked RedHat equivalents for entries whose branch was a copy. `service` is given only where
#: it differs from the package name or from Debian's unit; "" means "not stated" (the wizard shows
#: an empty service rather than a wrong one).
CORRECTIONS: dict[str, dict] = {
    # Different package name — the case that started this.
    "cron":                     {"packages": ["cronie"], "service": "crond"},
    "slapd":                    {"packages": ["openldap-servers"], "service": "slapd"},
    "krb5-kdc":                 {"packages": ["krb5-server"], "service": "krb5kdc"},
    "exim4":                    {"packages": ["exim"], "service": "exim", "user": "exim"},
    "redis-server":             {"packages": ["redis"], "service": "redis", "user": "redis"},
    "auditd":                   {"packages": ["audit"], "service": "auditd"},
    "pdns-server":              {"packages": ["pdns"], "service": "pdns"},
    "isc-dhcp-server":          {"packages": ["dhcp-server"], "service": "dhcpd"},
    "nfs-kernel-server":        {"packages": ["nfs-utils"], "service": "nfs-server"},
    "wireguard":                {"packages": ["wireguard-tools"], "service": ""},
    "prometheus-node-exporter": {"packages": ["golang-github-prometheus-node-exporter"],
                                 "service": "node_exporter"},
    # Same package name, but the unit or user differs, so the branch still carries information.
    # clamd@.service is in the clamd package (EPEL), not clamav — without it the unit does not exist (exit 5).
    "clamav":                   {"packages": ["clamav", "clamd"], "service": "clamd@scan"},
    "openvpn":                  {"packages": ["openvpn"], "service": "openvpn-server@server"},
    "nftables":                 {"packages": ["nftables"], "service": "nftables"},
    "spamassassin":             {"packages": ["spamassassin"], "service": "spamassassin"},
    "lighttpd":                 {"packages": ["lighttpd"], "service": "lighttpd"},
    "varnish":                  {"packages": ["varnish"], "service": "varnish"},
    "rabbitmq-server":          {"packages": ["rabbitmq-server"], "service": "rabbitmq-server"},
    "mosquitto":                {"packages": ["mosquitto"], "service": "mosquitto"},
    "collectd":                 {"packages": ["collectd"], "service": "collectd"},
    "etcd":                     {"packages": ["etcd"], "service": "etcd"},
    "podman":                   {"packages": ["podman"], "service": ""},
    "sudo":                     {"packages": ["sudo"], "service": ""},
}

#: Positively "not on this family". A NAMED non-existence, so the wizard can grey the action out
#: WITH a reason instead of attempting an install that cannot succeed. `instead` names the thing
#: to use; when it matches a catalog key the UI can link straight to that role.
UNAVAILABLE: dict[str, dict] = {
    "apparmor": {"unavailable": "RHEL and its rebuilds ship SELinux; AppArmor is not packaged.",
                 "instead": "SELinux (selinux-policy, enabled by default)"},
    # "not packaged for RHEL" was imprecise, and the EL name record (baseos/appstream/crb/epel) is what
    # showed it: ufw IS in EPEL. The operational statement is unchanged — firewalld is the platform's front
    # end — but a claim that a package does not exist, when it does, is the kind an operator disproves in one
    # `dnf install` and then trusts nothing else here.
    "ufw":      {"unavailable": "ufw is not in RHEL itself (only in EPEL); firewalld is the supported "
                                "front end for netfilter there.",
                 "instead": "firewalld"},
    "ntp":      {"unavailable": "The ntp daemon was dropped after RHEL 7; chrony replaces it and is "
                                "a separate role in this catalog.",
                 "instead": "chrony"},
}

#: The fourth axis. Package, service and config_path were already per-family; the account the
#: service runs as was not, although it differs just as much (www-data / apache / wwwrun) and
#: every file-ownership or "runs as" rule depends on it. Only entries whose user is actually
#: known appear here — an absent `user` reads as unknown, which is the truth.
USERS: dict[str, dict[str, str]] = {
    "apache2":    {"debian": "www-data", "redhat": "apache"},
    "nginx":      {"debian": "www-data", "redhat": "nginx"},
    "lighttpd":   {"debian": "www-data", "redhat": "lighttpd"},
    "php-fpm":    {"debian": "www-data", "redhat": "apache"},
    "postgresql": {"debian": "postgres", "redhat": "postgres"},
    "mariadb":    {"debian": "mysql", "redhat": "mysql"},
    "postfix":    {"debian": "postfix", "redhat": "postfix"},
    "dovecot":    {"debian": "dovecot", "redhat": "dovecot"},
    "bind9":      {"debian": "bind", "redhat": "named"},
    "squid":      {"debian": "proxy", "redhat": "squid"},
    "cups":       {"debian": "lp", "redhat": "lp"},
    "haproxy":    {"debian": "haproxy", "redhat": "haproxy"},
    "memcached":  {"debian": "memcache", "redhat": "memcached"},
    "varnish":    {"debian": "varnish", "redhat": "varnish"},
    "mosquitto":  {"debian": "mosquitto", "redhat": "mosquitto"},
    "rabbitmq-server": {"debian": "rabbitmq", "redhat": "rabbitmq"},
}


#: Corrections to the DEBIAN branch itself — the generators' own facts, measured against what the
#: .deb really ships. Same discipline as CORRECTIONS: a checked value in one readable place, with
#: the reason, instead of a heuristic that would guess again.
#: RedHat package names corrected against the REAL RPM repositories — the first time this branch's claims
#: were checked rather than curated from knowledge.
#:
#: All 40 roles with a redhat config_path were run through `dnf repoquery -l` in an EL9 container (see
#: scripts/rh_verify_claims.py): 20 verified exactly as claimed, 16 are shipped by no RPM in base+appstream,
#: and these 4 name a package that exists but does NOT ship the file. In every case `repoquery --file`
#: named the package that does, which is what makes this a correction rather than a guess.
#:
#: The pattern is the same one Debian had with libvirt-daemon: EL splits a service into a runtime package
#: and a -core/-common package that carries the configuration, and the obvious name is the wrong one.
REDHAT_FIXES: dict[str, dict] = {
    # --- the package exists but a DIFFERENT one ships the file (EL splits runtime from -core/-common) ---
    # A config file and no unit: the role wrote the file and restarted nothing. Each unit is the one the RPM ships
    # (rpm_source.fetch, usr/lib/systemd/system — measured 2026-10-11).
    "dovecot":    {"service": "dovecot", "why": "dovecot ships dovecot.service."},
    "keepalived": {"service": "keepalived", "why": "keepalived ships keepalived.service."},
    "ntpsec":     {"service": "ntpd", "why": "EL's ntpsec ships ntpd.service (Debian's: ntpsec.service)."},
    "prometheus": {"service": "prometheus", "why": "prometheus ships prometheus.service."},
    # Config file and unit as the RPM ships them (rpm_source.fetch, 2026-10-11); the family templates
    # squid-redhat, opendkim.conf-redhat and opendmarc.conf-redhat are made from the same files
    # (tools/template_from_shipped.py), field names = directive names, so the role's form fits both families.
    "squid":      {"config_path": "/etc/squid/squid.conf", "service": "squid", "why": "squid ships both."},
    # G3 (2026-10-11): installed-only on EL until now; file and unit as the RPM ships them, the family templates
    # rsyslog-redhat / mysql-server-redhat built from those files with the role's field names.
    "kea":        {"config_path": "/etc/kea/kea-dhcp4.conf", "service": "kea-dhcp4",
                   "why": "EL's kea ships /etc/kea/kea-dhcp4.conf and kea-dhcp4.service; family template kea-redhat "
                          "(same fields, the RPM's comments and log output)."},
    "rsyslog":    {"config_path": "/etc/rsyslog.conf", "service": "rsyslog", "why": "rsyslog ships /etc/rsyslog.conf "
                   "and rsyslog.service."},
    "mysql-server": {"config_path": "/etc/my.cnf.d/mysql-server.cnf", "service": "mysqld",
                     "why": "mysql-server (AppStream MySQL 8.0) ships /etc/my.cnf.d/mysql-server.cnf and mysqld.service."},
    "opendkim":   {"config_path": "/etc/opendkim.conf", "service": "opendkim",
                   "packages": ["opendkim", "opendkim-tools"],
                   "init": "test -e /etc/opendkim/keys/default.private || { opendkim-genkey -D /etc/opendkim/keys "
                           "-s default && chown opendkim:opendkim /etc/opendkim/keys/default.*; }",
                   "why": "opendkim ships both. EL's shipped config signs with /etc/opendkim/keys/default.private, which "
                          "no step creates (\"open(): No such file\"). opendkim-default-keygen SKIPS the key on a host "
                          "without a domain name (\"Cannot determine host's domain name\", rc 0 — measured), so the key "
                          "is made with opendkim-genkey (opendkim-tools) directly: the domain only names the DNS record "
                          "the operator publishes, the signing domain is configured separately."},
    "opendmarc":  {"config_path": "/etc/opendmarc.conf", "service": "opendmarc", "why": "opendmarc ships both."},
    "sshd":       {"init": "ssh-keygen -A",
                   "why": "EL creates the host keys when sshd first STARTS (sshd-keygen@.service); the role validates with "
                          "`sshd -t` before that and got \"no hostkeys available\". `ssh-keygen -A` creates exactly the "
                          "missing ones (idempotent) — what Debian's postinst does."},
    "isc-dhcp-server": {"config_path": "/etc/dhcp/dhcpd.conf",
                 "why": "EL9 ships /etc/dhcp/dhcpd.conf as a stub; the role had no file and started dhcpd without a "
                        "subnet. Now the family template isc-dhcp-server-redhat, `subnets` required — the same role as "
                        "on Debian."},
    "apache2":  {"packages": ["httpd", "httpd-core"],
                 "why": "/etc/httpd/conf/httpd.conf is shipped by httpd-core, not httpd (measured, EL9)."},
    "nginx":    {"packages": ["nginx", "nginx-core"],
                 "why": "/etc/nginx/nginx.conf is shipped by nginx-core, not nginx (measured, EL9)."},
    "samba":    {"packages": ["samba", "samba-common"],
                 "why": "/etc/samba/smb.conf is shipped by samba-common, not samba (measured, EL9)."},
    "libvirtd": {"packages": ["libvirt", "libvirt-daemon"],
                 "why": "/etc/libvirt/libvirtd.conf is shipped by libvirt-daemon, not libvirt or "
                        "qemu-kvm (measured, EL9) — the same split Debian has."},

    # --- the PATH was a Debian path. EL puts the file elsewhere, and `rpm -qc` said where ---
    "spamassassin": {"config_path": "/etc/mail/spamassassin/local.cf",
                     "why": "EL ships local.cf under /etc/mail/spamassassin/, not /etc/spamassassin/."},
    "collectd":     {"config_path": "/etc/collectd.conf",
                     "why": "EL ships one /etc/collectd.conf; the /etc/collectd/ directory is only "
                            "collectd.d for drop-ins."},
    "proftpd":      {"config_path": "/etc/proftpd.conf",
                     "why": "EL ships /etc/proftpd.conf at the top level; /etc/proftpd/ holds only conf.d."},
    "nftables":     {"config_path": "/etc/sysconfig/nftables.conf",
                     "why": "EL drives nftables from /etc/sysconfig/nftables.conf, which includes the "
                            "/etc/nftables/*.nft rule files. Debian's /etc/nftables.conf does not exist."},
    "exim4":        {"config_path": "/etc/exim/exim.conf",
                     "why": "The claim was /etc/exim4 — a DIRECTORY, and a Debian one at that. EL ships "
                            "/etc/exim/exim.conf."},
    "frr":          {"config_path": "/etc/frr/daemons", "service": "frr",
                     "why": "EL ships /etc/frr/daemons (which daemons run); frr.conf is written by the "
                            "operator or by vtysh, so nothing ships it."},

    # --- deliberately shipped by nothing; recording that is the point ---
    "openvpn":      {"config_path": "", "service": "",
                     "why": "openvpn declares NO %config at all and ships only /etc/openvpn/{client,server} "
                            "as directories — the admin writes the .conf. An empty path is the honest "
                            "answer; the claim was /etc/openvpn/crls, a directory. And no unit is started: "
                            "openvpn-server@server without that .conf and its keys failed on every host — "
                            "installed, not configured, as on Debian."},
    "clamav":       {"config_path": "/etc/clamd.d/scan.conf", "packages": ["clamav", "clamd", "clamav-freshclam"],
                     "init": "test -e /var/lib/clamav/main.cvd || test -e /var/lib/clamav/main.cld || freshclam",
                     "why": "clamd@scan reads /etc/clamd.d/scan.conf (shipped by clamav-filesystem with no socket "
                            "defined — the daemon refused to start); the clamd-scan-redhat template defines one. A "
                            "clamd without signatures cannot start either: freshclam fetches them once."},
    "freeradius":   {"init": "test -e /etc/raddb/certs/server.pem || "
                             "{ cd /etc/raddb/certs && ./bootstrap && chgrp -R radiusd /etc/raddb/certs; }",
                     "why": "EL does not create the EAP TLS certificates (Debian's postinst does): radiusd -C failed "
                            "\"Failed parsing configuration item private_key_file\" and the unit never started. "
                            "/etc/raddb/certs/bootstrap creates them once; radiusd -C then exits 0 (measured)."},
    "fail2ban":     {"config_path": "/etc/fail2ban/jail.local",
                     "why": "jail.local is the operator's override file on both families — shipped by neither, "
                            "written by the role (Debian's branch names the same file). The path had been cleared "
                            "by REDHAT_NOT_PACKAGED, which wrongly listed fail2ban: EPEL 9 ships it."},
    "postgresql":   {"config_path": "",
                     "init": "test -f /var/lib/pgsql/data/PG_VERSION || postgresql-setup --initdb",
                     "why": "postgresql.conf is created by initdb inside the data directory, so no RPM "
                            "ships it. /var/lib/pgsql/data/postgresql.conf was the right FILE and the "
                            "wrong claim: nothing to fetch, nothing to template. EL's postinst does not run "
                            "initdb (Debian's does): without `init` the unit refused to start on every fresh "
                            "host (Bossman-path baseline, cause needs-init)."},
}

#: RedHat roles whose package is in NEITHER base/appstream NOR EPEL — they need a vendor repo (Docker's
#: own, Traefik's) or are simply not packaged for EL. Recorded so the catalog stops implying a path that
#: no repository can supply: adminer, docker-ce, fail2ban, tftp-server, traefik.
#: Re-measured 2026-10-10 with `dnf repoquery` in the AlmaLinux 9 fetch container (BaseOS, AppStream, CRB, EPEL):
#: fail2ban (EPEL) and tftp-server (AppStream) ARE packaged — they were listed here and their path cleared while
#: the Bossman-path e2e installed and ran both. The rest are in no enabled repository, and the RedHat branch is now
#: marked unavailable WITH the reason (the wizard greys the role out) instead of only losing its path — adminer and
#: traefik were still offered and failed at `dnf install` with exit status 1.
REDHAT_NOT_PACKAGED: dict[str, str] = {
    "adminer": "adminer is not packaged for Enterprise Linux 9 (not in BaseOS, AppStream, CRB or EPEL).",
    "docker-daemon": "docker-ce comes from Docker's own repository, which is not enabled; EL9 ships podman instead.",
    "traefik": "Traefik is not packaged for Enterprise Linux 9; it ships as a binary or container image upstream.",
    "etcd": "etcd is not packaged for Enterprise Linux 9 (not in BaseOS, AppStream, CRB or EPEL).",
    "rabbitmq-server": "rabbitmq-server is not in the EL9 repositories; it comes from the RabbitMQ/PackageCloud repository.",
    "pacemaker": "pacemaker, corosync and pcs live in the EL9 HighAvailability repository, which is not enabled.",
    "prometheus-node-exporter": "node_exporter is not packaged for Enterprise Linux 9 (not in EPEL 9).",
}

DEBIAN_FIXES: dict[str, dict] = {
    # PACKAGE NAMES THAT DO NOT EXIST IN DEBIAN 13. Measured 2026-10-09 against trixie's own Packages index:
    # 11 roles named a package apt cannot find, and the Bossman-path e2e ended each with "apt-get install -y …:
    # exit status 100". Renamed upstream or provided under another name:
    "dovecot":      {"packages": ["dovecot-core", "dovecot-imapd"],
                     "why": "Debian splits dovecot; dovecot-core ships /etc/dovecot, imapd the IMAP service."},
    "ntp":          {"packages": ["ntpsec"],
                     "why": "trixie replaced the ntp package with ntpsec (same ntpd role, /etc/ntpsec/ntp.conf)."},
    "etcd":         {"packages": ["etcd-server"], "why": "trixie ships the daemon as etcd-server."},
    "proftpd":      {"packages": ["proftpd-core"], "why": "proftpd-basic became proftpd-core in trixie."},
    "mysql-server": {"packages": ["default-mysql-server"],
                     "why": "trixie has no mysql-server; default-mysql-server is Debian's MySQL-compatible server."},
    "conky-all":    {"packages": ["conky-all"], "why": "the package is conky-all; there is no plain conky."},
    "docker-daemon": {"packages": ["docker.io"],
                      "why": "docker-ce is Docker Inc.'s repository, not Debian; docker.io is Debian's dockerd."},
    # UNIT NAMES that no package of the role ships (checked against trixie's Contents index; exit status 5 —
    # "unit not found" — in the Bossman-path e2e):
    "exim4":        {"config_path": "/etc/exim4/update-exim4.conf.conf", "service": "exim4",
                     "why": "the template renders Debian's DC_* macro file; /etc/exim4 is the directory. The unit is "
                            "shipped by exim4-daemon-light, which exim4 pulls in."},
    "dlt.conf":     {"service": "dlt", "why": "dlt-daemon ships dlt.service, not dlt-daemon.service."},
    "php-fpm":      {"service": "php8.4-fpm", "config_path": "/etc/php/8.4/fpm/pool.d/www.conf", "why": "php-fpm is a metapackage; the unit is php8.4-fpm in trixie."},
    "cloud.cfg":    {"service": "", "why": "cloud-init reads cloud.cfg at boot; restarting a unit applies nothing."},
    "adminer":      {"packages": ["adminer", "apache2", "libapache2-mod-php"], "service": "apache2",
                     "init": "a2enconf adminer",
                     "why": "adminer is a PHP page; its configuration is an Apache snippet in conf-available, which does "
                            "nothing until it is enabled (a2enconf) and Apache reloads. The role therefore installs Apache "
                            "with PHP, enables the snippet and restarts apache2 — the earlier `service: \"\"` wrote a file "
                            "nothing read."},
    # G2 (2026-10-12): site values that are whole FILES, written by the role's `copy` step (wizard_seed._with_files).
    "ctdb.conf":    {"files": [{"path": "/etc/ctdb/nodes", "field": "ctdb_nodes", "mode": "0644",
                                "description": "The cluster's node addresses, one per line (ctdb refuses to start "
                                               "without them: ConditionFileNotEmpty=/etc/ctdb/nodes)"}],
                     "why": "ctdb.service has ConditionFileNotEmpty=/etc/ctdb/nodes — a list only the site has."},
    "prometheus-mysqld-exporter": {
                     "files": [{"path": "/var/lib/prometheus/.my.cnf", "field": "mysqld_exporter_my_cnf",
                                "mode": "0600", "owner": "prometheus", "group": "prometheus", "secret": True,
                                "description": "The [client] section the exporter connects with (user, password, "
                                               "host). Point the exporter at it with args "
                                               "`--config.my-cnf /var/lib/prometheus/.my.cnf` — its built-in default "
                                               "is a RELATIVE `.my.cnf`, which the unit (no WorkingDirectory) never "
                                               "finds (measured)"}],
                     "why": "the exporter logs \"Error parsing host config … no configuration found\" without "
                            "~prometheus/.my.cnf (credentials only the site has)."},
    "kea":          {"packages": ["kea-dhcp4-server"], "config_path": "/etc/kea/kea-dhcp4.conf",
                     "service": "kea-dhcp4-server",
                     "why": "Kea is configured and run per daemon; this role is the DHCPv4 server (G1, 2026-10-11): "
                            "kea-dhcp4-server ships /etc/kea/kea-dhcp4.conf and kea-dhcp4-server.service. The template "
                            "`kea` is the shipped file with subnet4 (required — a value only the site has, as for "
                            "isc-dhcp-server), interfaces and the lease timers as fields; the rest verbatim. "
                            "kea-dhcp4 -t verified against the shipped file."},
    "postgresql":   {"config_path": "/etc/postgresql/17/main/postgresql.conf",
                     "why": "trixie's postgresql depends on postgresql-17; the catalog's /etc/postgresql/*/main/... "
                            "was a pattern, which the engine now refuses (a literal '*' directory was written)."},
    "clamav":       {"packages": ["clamav", "clamav-daemon", "clamav-freshclam"], "service": "clamav-daemon",
                     "init": "test -e /var/lib/clamav/main.cvd || test -e /var/lib/clamav/main.cld || "
                             "{ systemctl stop clamav-freshclam; freshclam; rc=$?; systemctl start clamav-freshclam; exit $rc; }",
                     "why": "the role configures /etc/clamav/clamd.conf — the DAEMON's file — but installed only the "
                            "scanner and ran nothing, while the RedHat branch ran clamd: one role, two meanings. Both "
                            "families now run the daemon, with signatures fetched once (clamav-daemon's unit is skipped "
                            "until a database exists)."},
    "dnscache":     {"enable": False, "config_path": "",
                     "why": "dnscache's SysV script declares no runlevels (djbdns runs under daemontools/runit): "
                            "`systemctl enable` fails, `restart` works — the role starts it, not at boot. Its "
                            "'config' was /etc/init.d/dnscache, the init SCRIPT; djbdns is configured through one "
                            "file per variable in its env/ directory, which no template models — installed, not "
                            "configured, said."},
    "nsd":          {"config_path": "/etc/nsd/nsd.conf",
                     "why": "the index promoted /etc/init.d/nsd (the init script); nsd's configuration is nsd.conf, "
                            "which the nsd template renders."},
    "rbootd":       {"config_path": "/etc/default/rbootd",
                     "init": "mkdir -p /var/lib/rbootd",
                     "why": "the template renders the unit's EnvironmentFile (/etc/default/rbootd, IFACE=…); recorded "
                            "as /etc/rbootd.conf it wrote environment syntax into the file rbootd parses. The package "
                            "does not create /var/lib/rbootd, the boot-file directory rbootd(8) names, and the daemon "
                            "exits on `chdir` — created once. Measured: with it, rbootd stops one step later at \"no "
                            "boot files\" — the boot images a site supplies, which no package ships."},
    "isc-dhcp-server": {"service": "isc-dhcp-server",
                     "init": "grep -q '^INTERFACESv4=\"\"' /etc/default/isc-dhcp-server && sed -i \"s/^INTERFACESv4=\\\"\\\"/"
                             "INTERFACESv4=\\\"$(ls /sys/class/net | grep -vx lo | tr '\\n' ' ' | sed 's/ $//')\\\"/\" "
                             "/etc/default/isc-dhcp-server || true",
                     "why": "the role configured dhcpd.conf but named no unit, so on Debian it never started dhcpd and read "
                            "compliant without a running server — while on AlmaLinux the same role started dhcpd. One role, "
                            "one meaning: both start it, both require `subnets` (dhcpd refuses without one). Debian's init "
                            "script also starts a DHCPv6 server while INTERFACESv4 and INTERFACESv6 are both empty, and that "
                            "one always fails (\"No subnet6 declaration\"); the role configures DHCPv4 only, so INTERFACESv4 is "
                            "set once to every interface but lo — what dhcpd does with an empty list anyway (it serves the "
                            "interfaces whose network is declared and ignores the rest)."},
    "gnunet.conf":  {"init": "touch /var/log/gnunet.log && chown gnunet:gnunet /var/log/gnunet.log && "
                             "A=$(ls /usr/lib/*/gnunet/libexec/gnunet-service-arm | head -1) && "
                             "mkdir -p /etc/systemd/system/gnunet.service.d && "
                             "printf '[Service]\\nType=simple\\nExecStart=\\nExecStart=%s -c /etc/gnunet.conf\\nExecStop=\\n' "
                             "\"$A\" > /etc/systemd/system/gnunet.service.d/foreground.conf && systemctl daemon-reload",
                     "why": "Two causes, both measured. (1) gnunet-arm runs as gnunet and logs to /var/log/gnunet.log, "
                            "which nobody creates for it: \"`open' failed on file `/var/log/gnunet.log' … Permission "
                            "denied\", then an assertion, and ARM exits right after the fork. (2) The shipped unit is "
                            "Type=forking around `gnunet-arm -s` with no PIDFile: systemd guesses the main process (often "
                            "none, MainPID=0) and about one restart in five ends \"Deactivated successfully\" with every "
                            "gnunet process gone — compliant in one run, noncompliant in the next. Running ARM itself in "
                            "the foreground (Type=simple; its libexec path is per-architecture, hence resolved here) made "
                            "20 restarts in a row active, and a stop leaves no gnunet process behind."},
    "bip":          {"init": "[ -n \"$(systemctl show -p PIDFile --value bip)\" ] || { mkdir -p /etc/systemd/system/bip."
                             "service.d && printf '[Service]\\nPIDFile=/var/lib/bip/bip.pid\\n' > "
                             "/etc/systemd/system/bip.service.d/pidfile.conf && systemctl daemon-reload; }",
                     "why": "bip.service is Type=forking without a PIDFile, so systemd GUESSES the main process; when it "
                            "guesses the parent that exits, it reports the unit \"Deactivated successfully\" while bip "
                            "keeps running (KillMode=process) — compliant in one run, noncompliant in the next. bip writes "
                            "its pid to the -s directory (/var/lib/bip/bip.pid); a drop-in names it, only while the "
                            "packaged unit names none."},
    "biboumi":      {"init": "install -d -o _biboumi -g _biboumi /var/lib/biboumi/.config/biboumi",
                     "why": "biboumi keeps its SQLite database under its home's XDG config dir, which the package does not "
                            "create (\"Failed to open database file /var/lib/biboumi/.config/biboumi/biboumi.sqlite\") — "
                            "created once, owned by _biboumi. hostname and password are required site values."},
    "iodined":      {"config_path": "/etc/default/iodine",
                     "why": "the index picked /etc/logcheck/ignore.d.server/iodined (a logcheck rule file) for an invented "
                            "template. iodined.service reads /etc/default/iodine (IODINED_ARGS, IODINED_PASSWORD), written "
                            "by the postinst; tunnel_ip, topdomain and password are required site values, so the preview "
                            "names them instead of deploying a daemon that cannot start."},
    "autossh":      {"config_path": "", "why": "the package ships no system configuration file — only a logcheck rule file, which the index picked and which its template does not even describe (autossh is configured per tunnel, on the command line)."},
    "gpg-agent":    {"config_path": "", "why": "the package ships no system configuration file — only a logcheck rule file, which the index picked and which its template does not even describe (gpg-agent.conf is per user, in ~/.gnupg)."},
    "talkd":        {"config_path": "", "why": "the package ships no system configuration file — only a logcheck rule file, which the index picked and which its template does not even describe (talkd is enabled through inetd)."},
    # The unit is named differently from the role and its package (configs/debian_package_units.json shows it):
    "collectd":     {"service": "collectd", "why": "the unit is shipped by collectd-core, which collectd pulls in."},
    "pdns-server":  {"service": "pdns", "why": "pdns-server ships pdns.service."},
    "sssd":         {"service": "sssd",
                     "init": "test -e /etc/sssd/sssd.conf || install -m 0600 -o root -g root /dev/null /etc/sssd/sssd.conf",
                     "why": "the unit is shipped by sssd-common, which sssd pulls in. sssd refuses a sssd.conf that is not "
                            "0600 root (\"File ownership and permissions check failed\"); no package ships the file and "
                            "template_render creates new files 0644 — so it is created empty with 0600 first, and the "
                            "render keeps an existing file's mode."},
    "openvpn":      {"config_path": "",
                     "why": "the index recorded /etc/openvpn/crls — a directory. OpenVPN is configured per instance "
                            "(/etc/openvpn/server/<name>.conf + keys), which no template models: installed, not "
                            "configured, said."},
    "bacula-director": {"config_path": "",
                     "why": "the postinst generates /etc/bacula/bacula-dir.conf with random passwords paired with the "
                            "storage and file daemons' configurations; the template replacing it was invented (bacula: "
                            "\"Keyword Port not permitted in this resource\") and would break those pairings even if valid. "
                            "Clients, jobs and pools are site decisions no template models — installed, not configured."},
    "ssmtp":        {"config_path": "/etc/ssmtp/ssmtp.conf",
                     "why": "the index recorded /etc/logcheck/ignore.d.server/ssmtp (a logcheck rule file) for a template of "
                            "ssmtp.conf; ssmtp.conf is written by the postinst, its keys are those of ssmtp.conf(5)."},
    "syslog-ng-core": {"config_path": "/etc/default/syslog-ng", "service": "syslog-ng.service",
                     "why": "the template is /etc/default/syslog-ng (CONSOLE_LOG_LEVEL, SYSLOGNG_OPTS), the unit's "
                            "EnvironmentFile — recorded as syslog-ng.conf it would have written shell variables into the "
                            "daemon's configuration language. A change applies on restart, so the role names the unit."},
    "openiked":     {"config_path": "",
                     "why": "iked.conf ships as a commented example of one IKEv2 policy (local/peer addresses, PSK); every "
                            "field of its template sat inside that comment and changed nothing. A policy is site-specific and "
                            "no template models it — installed, not configured, said."},
    "epic4":        {"config_path": "",
                     "why": "/etc/epic4/epic4.irc is the client's global startup SCRIPT; its template's three fields were "
                            "words inside prose comments. Nothing to configure for a host — installed, not configured, said."},
    "dns-flood-detector": {
                     "init": "test -x /usr/sbin/dns-flood-detector || { mkdir -p /etc/systemd/system/dns-flood-detector."
                             "service.d && printf '[Service]\\nType=forking\\nExecStart=\\nExecStart=/usr/bin/"
                             "dns-flood-detector $DAEMON_OPTS\\n' > /etc/systemd/system/dns-flood-detector.service.d/"
                             "unit-fix.conf && systemctl daemon-reload; }",
                     "why": "two defects in the shipped unit: it starts /usr/sbin/dns-flood-detector while the package "
                            "installs /usr/bin/ (\"Failed at step EXEC\"), and it is Type=notify while the shipped "
                            "DAEMON_OPTS run the daemon with -d, which forks and never reports ready (\"did not take the "
                            "steps required by its unit configuration\"). A drop-in sets the binary's path and "
                            "Type=forking, and retires itself (`test -x`) once the package's path is right. Measured on "
                            "a fresh host: NotifyAccess=all does not help, -b (foreground) never sends READY, "
                            "Type=forking with -d runs."},
    "osmo-hlr":     {"init": "getent passwd osmocom >/dev/null || adduser --system --group --no-create-home osmocom",
                     "why": "the unit runs as User=osmocom, which no trixie package creates (\"Failed at step USER spawning …: No such process\", 217/USER). The role creates the system user once, as an administrator would."},
    "osmo-stp":     {"init": "getent passwd osmocom >/dev/null || adduser --system --group --no-create-home osmocom",
                     "why": "the unit runs as User=osmocom, which no trixie package creates (\"Failed at step USER spawning …: No such process\", 217/USER). The role creates the system user once, as an administrator would."},
    "mandos":       {"init": "systemctl enable --now avahi-daemon",
                     "why": "mandos.service has Requisite=avahi-daemon.service: avahi must ALREADY run, and installing it "
                            "does not start it (\"Dependency failed for mandos.service\"). Measured on a fresh host: "
                            "with avahi active, mandos starts and stays up."},
    "rsync":        {"config_path": "/etc/rsyncd.conf",
                     "why": "rsync.service starts only when /etc/rsyncd.conf exists (ConditionPathExists) and no package "
                            "ships it; the role wrote /etc/default/rsync, \"only used for init.d based systems\". The "
                            "rsyncd.conf template is the package's example (/usr/share/doc/rsync/examples), modules a list."},
    "radicale":     {"config_path": "/etc/radicale/config",
                     "init": "chown radicale:radicale /var/lib/radicale/collections",
                     "why": "radicale reads /etc/radicale/config; its unit has no EnvironmentFile, so /etc/default/radicale "
                            "changed nothing. The package leaves /var/lib/radicale/collections root-owned while the daemon "
                            "runs as radicale (\"Permission denied: …/collection-root\") — handed over once."},
    "miredo":       {"config_path": "/etc/miredo.conf",
                     "why": "the unit reads only /etc/miredo/miredo.conf (`miredo-checkconf -f`, then `miredo -f`), a "
                            "symlink to /etc/miredo.conf; the role wrote /etc/default/miredo, which no unit reads."},
    "anacrontab":   {"service": "anacron.timer", "why": "anacron.service runs the due jobs and exits (Type=simple, "
                                                         "triggered by anacron.timer); \"running\" is the timer being "
                                                         "active — the service is inactive between runs by design."},
    "linuxptp":     {"service": "", "why": "ptp4l.conf is read by ptp4l@<interface>.service, which needs an interface "
                                           "name; timemaster (the unit the index promoted) reads timemaster.conf and "
                                           "spawns chronyd — restarting it applies nothing of ptp4l.conf."},
    "apt.conf":     {"packages": ["apt"], "config_path": "/etc/apt/apt.conf",
                     "why": "aptdaemon/ubuntu-pro-client/update-notifier-common are Ubuntu packages, 01-vendor-ubuntu an Ubuntu file; "
                            "apt reads /etc/apt/apt.conf when present."},
    "libvirtd": {
        "packages": ["libvirt-daemon-system", "libvirt-daemon", "qemu-system-x86"],
        "why": "libvirt-daemon-system and qemu-system-x86 ship NOTHING under /etc (measured). The "
               "17 kB /etc/libvirt/libvirtd.conf comes from libvirt-daemon, which the role never "
               "named — so the config could not be found and the role stayed permanently "
               "unconfigurable. Installing libvirt-daemon-system pulls it in anyway, so naming it "
               "costs nothing and makes the config reachable.",
    },
    "pure-ftpd": {
        "config_path": "/etc/pure-ftpd/conf",
        "packages": ["pure-ftpd", "pure-ftpd-common"],
        "why": "Debian DOES ship /etc/pure-ftpd/pure-ftpd.conf (from pure-ftpd-common) — an earlier "
               "note here claimed otherwise and was wrong. What is true is that the service never "
               "READS it: pure-ftpd-wrapper does opendir('/etc/pure-ftpd/conf') and turns each file "
               "in that directory into one command-line flag. Editing the .conf would appear to work "
               "and change nothing, which is worse than no editor — so the debian branch points at "
               "the directory, edited with the dirvalue codec. RedHat really does use a single "
               "pure-ftpd.conf, so only debian is corrected. pure-ftpd-common is added because it is "
               "the package that actually ships the config, the same trap as libvirtd.",
    },
}

#: Entries that are a second name for another entry. Keyed by the one to REMOVE, valued by the
#: survivor and why — a dedup heuristic would be guessing, and merging catalog entries silently is
#: exactly the kind of thing that should be readable.
DUPLICATES: dict[str, dict[str, str]] = {
    "mariadb-server": {
        "keep": "mariadb",
        "why": "Same daemon, same file (/etc/mysql/mariadb.conf.d/50-server.cnf) twice: the curated `mariadb` "
               "(compliant) and the classified `mariadb-server`, whose invented template made mariadb abort once the "
               "role restarted it. One service, one role.",
    },
    "openssh-server": {
        "keep": "sshd",
        "why": "Same daemon twice: the feature `openssh-server` rendered an invented sshd_config whose defaults were empty "
               "values (`Port `, `PermitRootLogin ` — sshd refused it: \"line 11: unsupported option\"; on a real host "
               "that is a lockout), next to the curated role `sshd`. sshd survives with sshd_config / "
               "sshd_config-redhat, built from each family's shipped file and checked with `sshd -t`.",
    },
    "ntp": {
        "keep": "ntpsec",
        "why": "Same daemon twice on Debian: `ntp` and `ntpsec` both configured /etc/ntpsec/ntp.conf for ntpsec.service. "
               "ntpsec — the package and the daemon — survives, with the Debian-faithful ntp.conf template (and the "
               "template it already used on AlmaLinux as ntp.conf-redhat).",
    },
    "redis-server": {
        "keep": "redis",
        "why": "Same daemon, same template, same file twice: `redis` (curated, restarts redis-server) and `redis-server` "
               "(classified, restarted nothing on Debian). One service, one role.",
    },
    "mpd": {
        "keep": "mpd.conf",
        "why": "Same daemon twice: `mpd` configured /etc/default/mpd (one field, inside a comment) and `mpd.conf` the "
               "daemon's own /etc/mpd.conf (audio outputs, verified with mpd). One service, one role.",
    },
    "nfs-kernel-server": {
        "keep": "nfs.conf",
        "why": "Same thing twice: both resolve to /etc/nfs.conf and to nfs-kernel-server (deb) / "
               "nfs-utils (rpm). nfs.conf survives because the SETTING is what is shared across "
               "families — the path is identical on Debian and RHEL while the package name is not "
               "— and it has the real schema (20 fields vs 1). Exports keep their own snap-in.",
    },
}


#: Templates WITHDRAWN by decision, with the reason the wizard shows — measured defects no regeneration can fix
#: because the package ships no file to parametrize. The role still installs; it does not pretend to configure.
TEMPLATE_WITHDRAWN: dict[str, str] = {
    "openvpn": "The template reads 13 `server.*` values its schema does not declare, and Debian ships no server.conf "
               "to rebuild it from (the role's path /etc/openvpn/crls is a directory). Configure OpenVPN per "
               "instance (/etc/openvpn/server/<name>.conf) until a template exists.",
}


#: Positively "not packaged in Debian 13" — named, so the wizard greys the role out with the reason instead of an
#: install that fails with exit status 100 (measured, as above).
DEBIAN_UNAVAILABLE: dict[str, str] = {
    "mongodb": "MongoDB is not packaged in Debian (licence); install it from MongoDB's own repository.",
    "traefik": "Traefik is not packaged in Debian 13; it ships as a binary or container image upstream.",
    "bind9-redhat": "This entry is the RedHat build of BIND; on Debian use the bind9 role.",
    "mysql-server": "Debian's MySQL server is MariaDB (default-mysql-server); use the mariadb role. This entry wrote "
                    "/etc/mysql/mysql.conf.d/mysqld.cnf, which MariaDB never reads.",
}


#: The index-promoted description: "Configure /etc/default/rsync (shipped by rsync)."
AUTO_DESCRIPTION = re.compile(r"^Configure (\S+) \((?:shipped|provided) by [^)]*\)\.$")


#: Units a package ships that are NOT the daemon its configuration belongs to: restarting them applies nothing.
NOT_A_SERVICE = {
    "sudo": "sudo.service only cleans up stale timestamps at boot; sudoers is read on every invocation.",
}


def _load_units() -> dict[str, list[str]]:
    try:
        data = json.loads((configs_dir(__file__) / "debian_package_units.json").read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def curate(catalog: dict, attested: set[str], core: set[str]) -> tuple[dict, dict]:
    """Return `(catalog, report)`. Pure — the caller decides whether to write."""
    report = {"kept": [], "curated": [], "unavailable": [], "dropped": [], "users": 0,
              "no_template": [], "merged": [], "restored": [], "debian_fixed": [],
              "paths_filled": [], "paths_still_empty": [], "retargeted": [],
              "redhat_fixed": [], "redhat_unpackaged": []}

    for name, spec in DUPLICATES.items():
        if name in catalog and spec["keep"] in catalog:
            del catalog[name]
            report["merged"].append(f"{name} → {spec['keep']}")

    for name, why in DEBIAN_UNAVAILABLE.items():
        fams = (catalog.get(name) or {}).get("families")
        if isinstance(fams, dict) and isinstance(fams.get("debian"), dict) and not fams["debian"].get("unavailable"):
            fams["debian"] = {"unavailable": why, "source": "curated"}
            report["debian_fixed"].append(f"{name}: unavailable")

    for name, fix in DEBIAN_FIXES.items():
        deb = ((catalog.get(name) or {}).get("families") or {}).get("debian")
        if not isinstance(deb, dict):
            continue
        for field in ("packages", "config_path", "service", "enable", "init", "files"):
            if field in fix and deb.get(field) != fix[field]:
                deb[field] = fix[field]
                report["debian_fixed"].append(f"{name}.{field}")
        # The index writes "Configure <path> (shipped by …)." — after a path fix that sentence names the file the
        # role no longer touches (rsync said /etc/default/rsync while configuring /etc/rsyncd.conf). One file, one name.
        desc = catalog[name].get("description") or ""
        m = AUTO_DESCRIPTION.match(desc)
        if fix.get("config_path") and m and m.group(1) != fix["config_path"]:
            catalog[name]["description"] = f"Configure {fix['config_path']}."

    # AN EMPTY DEBIAN `service` IS NAMED FROM THE ARCHIVE. Roles the classify step promoted from tasksel/comps carried
    # service "" on Debian, so the wizard wrote the file and restarted nothing (redis.conf changed, redis kept the old
    # settings) — and the e2e, having no unit to look at, counted those roles compliant on the file alone. The unit is
    # taken only where the package SHIPS one named exactly after the role or one of its packages
    # (configs/debian_package_units.json, read from the Contents index by tools/debian_units.py); a decision recorded in
    # DEBIAN_FIXES (a service, enable False, or config_path "") wins, and NOT_A_SERVICE names units that are not the
    # daemon a configuration change should restart.
    units = _load_units()
    for name, entry in catalog.items():
        deb = (entry.get("families") or {}).get("debian")
        if entry.get("kind") not in ("role", "feature") or not isinstance(deb, dict) or deb.get("service") \
                or deb.get("unavailable") or deb.get("enable") is False:
            continue
        fix = DEBIAN_FIXES.get(name) or {}
        if "service" in fix or fix.get("config_path") == "" or name in NOT_A_SERVICE:
            continue
        shipped = {u for pkg in deb.get("packages") or [] for u in units.get(pkg, [])}
        pick = next((u for u in [name, *(deb.get("packages") or [])] if u in shipped), None)
        if pick:
            deb["service"] = pick
            report["debian_fixed"].append(f"{name}.service = {pick} (shipped unit)")

    # An EMPTY debian config_path is repaired from the grounded resolver, not from a hand table.
    #
    # 30 of 89 roles carried "" here, because classify_roles_features derived the path from the codec
    # registry alone and its stem rule cannot see /etc/crontab for `cron`, /etc/sudoers for `sudo` or
    # /etc/rsyslog.conf for `rsyslog`. Those entries are PRESERVED by every later catalog rebuild
    # (build_package_catalog step 4), so fixing the resolver alone would leave them empty forever —
    # a repaired rule with unrepaired data is a rule nobody can observe working.
    #
    # Only ever fills an EMPTY path: a non-empty one was either measured or curated, and this pass is
    # not entitled to overrule it. main_config_path is the same function the classifier now uses, so
    # new rows and repaired rows cannot disagree.
    codecs = _load_codecs()
    seed_pkgs = _seed_packages()
    for name, entry in catalog.items():
        deb = (entry.get("families") or {}).get("debian")
        if not isinstance(deb, dict) or deb.get("config_path"):
            continue
        # A path emptied BY DECISION (DEBIAN_FIXES config_path "": dnscache, openiked, epic4 — "installed, not
        # configured, said") is not a gap to fill: the resolver found /etc/iked.conf again and undid it.
        if (DEBIAN_FIXES.get(name) or {}).get("config_path") == "":
            report["paths_still_empty"].append(f"{name} (decided)")
            continue
        pkgs = deb.get("packages") or [name]
        found = next((p for p in (main_config_path(pkg, codecs, seed_pkgs) for pkg in pkgs) if p), "")
        if found:
            deb["config_path"] = found
            report["paths_filled"].append(f"{name} → {found}")
        else:
            # NAMED, not silent. An empty path is a legitimate state — the wizard resolves it from the
            # installed package at runtime — but "we found none" and "nobody looked" must not read the
            # same. Reported so the remainder is a visible list rather than an absence.
            report["paths_still_empty"].append(name)

    # RETARGET FIRST, as its own pass. TEMPLATE_ALIAS is a curated statement — "this role's template is
    # that directory" — decided by a person who read both. It is not a repair branch for a failed gate,
    # and putting it inside one was wrong: `chrony` PASSES the gate (it places 1 of its 12 fields) while
    # still rendering /etc/default/chrony against a config_path of /etc/chrony/chrony.conf, so the
    # correction never fired. The builder already honours the alias unconditionally for CORE entries;
    # this is the same rule applied to a catalog the builder did not regenerate.
    for name, entry in catalog.items():
        alias = TEMPLATE_ALIAS.get(name)
        # The alias directory must HAVE a template: a directory holding only meta.json (its target recorded so
        # `qualify_packages --repair` may regenerate it) answers "unknown", and retargeting to it pointed ntp and
        # opendmarc at nothing to render until the regeneration ran.
        import bossman.tools.build_package_catalog as _B
        if (alias and entry.get("template") and entry["template"] != alias
                and (_B.TEMPLATES_DIR / alias / "template.j2").is_file()
                and _template_configures(alias) is not False):
            report["retargeted"].append(f"{name}: {entry['template']} → {alias}")
            entry["template"] = alias

    for name, entry in catalog.items():
        if entry.get("template") and _template_configures(entry["template"]) is False:
            # Withdrawal is right when NO template configures the file. Anything salvageable was
            # retargeted above, so reaching here means the action cannot succeed and is not offered.
            entry["template"] = None
            report["no_template"].append(name)
        elif not entry.get("template") and _template_configures(TEMPLATE_ALIAS.get(name, name)) is True:
            # RESTORE. A withdrawal has to be reversible, or it is not a state but a verdict.
            # build_package_catalog PRESERVES entries it does not regenerate, so a `template: null`
            # written here survives every later rebuild — which means a template that was actually
            # repaired would stay withdrawn forever and the repair would be invisible. Measured:
            # after qwen regenerated varnish from the right file (8 of 8 fields used), the catalog
            # still said null.
            #
            # Safe because it is the same predicate in the other direction: restored only when a
            # template directory of that name demonstrably configures its own file.
            entry["template"] = TEMPLATE_ALIAS.get(name, name)
            report["restored"].append(name)

    for name, why in TEMPLATE_WITHDRAWN.items():
        if name in catalog and catalog[name].get("template"):
            catalog[name]["template"] = None
            catalog[name]["template_withdrawn"] = why
            report["no_template"].append(f"{name} (withdrawn: decision)")

    for name, entry in catalog.items():
        fams = entry.get("families")
        if not isinstance(fams, dict):
            continue

        before = json.dumps(fams.get("redhat"), sort_keys=True)

        if name in UNAVAILABLE:
            fams["redhat"] = {**UNAVAILABLE[name], "source": "curated"}
            bucket = "unavailable"
        else:
            debian, redhat = fams.get("debian") or {}, fams.get("redhat")
            if not isinstance(redhat, dict) or redhat.get("unavailable"):
                bucket = None                        # already absent, or already a named gap
            elif redhat.get("packages") != debian.get("packages"):
                bucket = "kept"                      # a real translation, left alone
            elif name in CORRECTIONS:
                # Carry `user` across: the correction states package/service, not the account, so
                # replacing the branch outright would drop a value USERS had already set — and the
                # next run would "fill" it again, reporting work that only undid its own wipe.
                # PRESENCE, not truthiness. This filter used to be `and v`, which dropped an
                # intentionally EMPTY config_path — and "" is a real answer here: openvpn declares no
                # %config at all and postgresql's is created by initdb, so no RPM ships either. The empty
                # value was wiped on every run and re-applied by the measured-facts pass below, which then
                # reported a fix forever. The comment above already named that failure mode; the predicate
                # just did not implement it.
                carry = {k: v for k, v in redhat.items() if k in ("config_path", "user")}
                fams["redhat"] = {**carry, **CORRECTIONS[name], "source": "curated"}
                bucket = "curated"
            elif name in core or any(p in attested for p in redhat.get("packages") or []):
                redhat["source"] = "curated" if name in core else "verified"
                bucket = "kept"
            else:
                fams.pop("redhat")
                bucket = "dropped"

        # The fourth axis LAST: a correction above replaces the whole branch, so filling `user`
        # first would have it wiped and refilled on every run — a script that reports work it did
        # not do is the same defect this whole change is about.
        for family, who in (USERS.get(name) or {}).items():
            if isinstance(fams.get(family), dict) and not fams[family].get("user"):
                fams[family]["user"] = who
                report["users"] += 1

        # Report what CHANGED, not what was considered. Re-running a settled catalog must say so.
        if bucket and json.dumps(fams.get("redhat"), sort_keys=True) != before:
            report[bucket].append(name)
        elif bucket == "kept":
            report["kept"].append(name)
    return catalog, report


def run(dry_run: bool = False) -> int:
    """Curate the catalog ON DISK. Split from main() so build_package_catalog can call it as the second
    half of one operation: argparse inside the callee would parse the CALLER's argv, and a rebuild that
    stops before this point silently strips the curated redhat branches — measured, 24 entries, including
    apache2 losing `httpd-core` and its `user`, and adminer having an intentionally EMPTY config_path
    replaced by a guess."""
    catalog = json.loads(CATALOG.read_text())
    attested, sources = _attested_el_names()
    print(f"attestation: {len(attested)} EL package names from {', '.join(sources) or 'NOTHING'}")

    catalog, report = curate(catalog, attested, _core_keys())

    # RedHat, measured against the real repos in an EL9 container. RUNS LAST, after the family-branch
    # pass, and that order is load-bearing: the CORRECTIONS branch there REPLACES the whole redhat dict
    # and carries config_path over only `if v` — so an intentionally EMPTY path (openvpn, postgresql:
    # shipped by nothing, and saying so is the point) was dropped and re-applied on every run. Measured
    # facts are the strongest evidence here, so they are applied after everything that curates. (scripts/rh_verify_claims.py +
    # rh_what_ships.py). Of 40 curated redhat config_paths: 23 verified untouched, 4 named the wrong
    # package, 6 carried a DEBIAN path, 2 are shipped by nothing by design, 5 are not packaged for EL at
    # all. Only the first four kinds are fixable here; the last is recorded in REDHAT_NOT_PACKAGED.
    for name, fix in REDHAT_FIXES.items():
        rh = ((catalog.get(name) or {}).get("families") or {}).get("redhat")
        if not isinstance(rh, dict):
            continue
        for field in ("packages", "config_path", "service", "init", "files"):
            if field in fix and rh.get(field) != fix[field]:
                rh[field] = fix[field]
                rh["source"] = "verified"
                report["redhat_fixed"].append(f"{name}.{field}")

    # AN EXECUTED SCRIPT IS NOT A CONFIGURATION FILE. The index promoted init scripts and cron jobs as a role's
    # config_path (dnscache, nsd, rbldns: /etc/init.d/…; aptitude, awffull, check-dfsg-status: /etc/cron.*/…), so the
    # wizard would have overwritten the script from a template. One rule with the worklist (package_e2e_worklist.SCRIPT):
    # such a path is cleared — installed, not configured — unless a fix above named the real file.
    from bossman.tools.package_e2e_worklist import SCRIPT as _SCRIPT
    # DOCUMENTATION IS NOT CONFIGURATION, and an example is the template of the file the admin writes. apticron,
    # comgt and netscript-ipfilter named a README as their config_path; btrbk and fcm named "*.example". A README
    # path is cleared; an example path becomes the file without the suffix (same format, the file actually read).
    import re as _re
    report.setdefault("doc_paths", [])
    for name, entry in catalog.items():
        for fam, branch in ((entry or {}).get("families") or {}).items():
            path = branch.get("config_path") if isinstance(branch, dict) else ""
            if not path:
                continue
            if _re.search(r"/README[^/]*$", path):
                report["doc_paths"].append(f"{name}.{fam}: {path} → (none)")
                branch["config_path"] = ""
            elif _re.search(r"\.(example|sample|dist)$", path):
                real = _re.sub(r"\.(example|sample|dist)$", "", path)
                report["doc_paths"].append(f"{name}.{fam}: {path} → {real}")
                branch["config_path"] = real
    report.setdefault("script_paths", [])
    for name, entry in catalog.items():
        for fam, branch in ((entry or {}).get("families") or {}).items():
            if isinstance(branch, dict) and _SCRIPT.search(branch.get("config_path") or ""):
                report["script_paths"].append(f"{name}.{fam}: {branch['config_path']}")
                branch["config_path"] = ""

    for name, why in REDHAT_NOT_PACKAGED.items():
        fams = (catalog.get(name) or {}).get("families")
        if isinstance(fams, dict) and isinstance(fams.get("redhat"), dict) and fams["redhat"].get("unavailable") != why:
            fams["redhat"] = {"unavailable": why, "source": "verified"}
            report["redhat_unpackaged"].append(name)

    print(f"kept        {len(report['kept']):3d}  real translation, CORE decision, or attested in the RedHat universe")
    print(f"curated     {len(report['curated']):3d}  {', '.join(sorted(report['curated'])) or '—'}")
    print(f"unavailable {len(report['unavailable']):3d}  {', '.join(sorted(report['unavailable'])) or '—'}")
    print(f"dropped     {len(report['dropped']):3d}  copied and unattested → the entry now reads 'not curated for redhat'")
    print(f"users       {report['users']:3d}  fourth axis filled")
    print(f"merged      {len(report['merged']):3d}  {', '.join(report['merged']) or '—'}")
    print(f"redhat fix  {len(report['redhat_fixed']):3d}  measured against the EL9 repos: "
          f"{', '.join(sorted(report['redhat_fixed'])) or '—'}")
    print(f"redhat n/a  {len(report['redhat_unpackaged']):3d}  not packaged for EL, marked unavailable: "
          f"{', '.join(sorted(report['redhat_unpackaged'])) or '—'}")
    print(f"debian fix  {len(report['debian_fixed']):3d}  {', '.join(sorted(report['debian_fixed'])) or '—'}")
    print(f"doc path    {len(report.get('doc_paths', [])):3d}  README cleared / example → the real file: "
          f"{', '.join(sorted(report.get('doc_paths', []))) or '—'}")
    print(f"script path {len(report.get('script_paths', [])):3d}  an executed script was the config_path — cleared: "
          f"{', '.join(sorted(report.get('script_paths', []))) or '—'}")
    print(f"paths filled{len(report['paths_filled']):3d}  empty debian config_path resolved from the "
          f"codec registry + seed witness")
    for line in sorted(report["paths_filled"]):
        print(f"            {line}")
    print(f"paths empty {len(report['paths_still_empty']):3d}  no grounded path — the wizard resolves it "
          f"from the installed package")
    if report["paths_still_empty"]:
        print("            " + ", ".join(sorted(report["paths_still_empty"])))
    print(f"retargeted  {len(report['retargeted']):3d}  wrong template dir → the right one: "
          f"{', '.join(sorted(report['retargeted'])) or '—'}")
    print(f"restored    {len(report['restored']):3d}  template repaired → Configure offered again: "
          f"{', '.join(sorted(report['restored'])) or '—'}")
    print(f"no template {len(report['no_template']):3d}  template did not configure its own file "
          f"→ Configure withdrawn")
    if report["no_template"]:
        print("            " + ", ".join(sorted(report["no_template"])))
    if report["dropped"]:
        print("            " + ", ".join(sorted(report["dropped"])))

    if dry_run:
        print("\n--dry-run: nothing written")
        return 0
    CATALOG.write_text(json.dumps(catalog, indent=2, ensure_ascii=False, sort_keys=True) + "\n")
    print(f"\nwrote {CATALOG}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true", help="report what would change, write nothing")
    args = ap.parse_args()
    return run(dry_run=args.dry_run)


if __name__ == "__main__":
    raise SystemExit(main())
