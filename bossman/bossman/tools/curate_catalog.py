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
    "clamav":                   {"packages": ["clamav"], "service": "clamd@scan"},
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
    "frr":          {"config_path": "/etc/frr/daemons",
                     "why": "EL ships /etc/frr/daemons (which daemons run); frr.conf is written by the "
                            "operator or by vtysh, so nothing ships it."},

    # --- deliberately shipped by nothing; recording that is the point ---
    "openvpn":      {"config_path": "",
                     "why": "openvpn declares NO %config at all and ships only /etc/openvpn/{client,server} "
                            "as directories — the admin writes the .conf. An empty path is the honest "
                            "answer; the claim was /etc/openvpn/crls, a directory."},
    "postgresql":   {"config_path": "",
                     "why": "postgresql.conf is created by initdb inside the data directory, so no RPM "
                            "ships it. /var/lib/pgsql/data/postgresql.conf was the right FILE and the "
                            "wrong claim: nothing to fetch, nothing to template."},
}

#: RedHat roles whose package is in NEITHER base/appstream NOR EPEL — they need a vendor repo (Docker's
#: own, Traefik's) or are simply not packaged for EL. Recorded so the catalog stops implying a path that
#: no repository can supply: adminer, docker-ce, fail2ban, tftp-server, traefik.
REDHAT_NOT_PACKAGED = ("adminer", "docker-daemon", "fail2ban", "tftpd-hpa", "traefik")

DEBIAN_FIXES: dict[str, dict] = {
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
    "nfs-kernel-server": {
        "keep": "nfs.conf",
        "why": "Same thing twice: both resolve to /etc/nfs.conf and to nfs-kernel-server (deb) / "
               "nfs-utils (rpm). nfs.conf survives because the SETTING is what is shared across "
               "families — the path is identical on Debian and RHEL while the package name is not "
               "— and it has the real schema (20 fields vs 1). Exports keep their own snap-in.",
    },
}


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

    for name, fix in DEBIAN_FIXES.items():
        deb = ((catalog.get(name) or {}).get("families") or {}).get("debian")
        if not isinstance(deb, dict):
            continue
        for field in ("packages", "config_path"):
            if field in fix and deb.get(field) != fix[field]:
                deb[field] = fix[field]
                report["debian_fixed"].append(f"{name}.{field}")

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
        if (alias and entry.get("template") and entry["template"] != alias
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
        for field in ("packages", "config_path"):
            if field in fix and rh.get(field) != fix[field]:
                rh[field] = fix[field]
                rh["source"] = "verified"
                report["redhat_fixed"].append(f"{name}.{field}")

    for name in REDHAT_NOT_PACKAGED:
        rh = ((catalog.get(name) or {}).get("families") or {}).get("redhat")
        if isinstance(rh, dict) and rh.get("config_path"):
            # The path is not wrong so much as unreachable: no repo we can enable ships that package.
            rh["config_path"] = ""
            rh["source"] = "verified"
            report["redhat_unpackaged"].append(name)

    print(f"kept        {len(report['kept']):3d}  real translation, CORE decision, or attested in the RedHat universe")
    print(f"curated     {len(report['curated']):3d}  {', '.join(sorted(report['curated'])) or '—'}")
    print(f"unavailable {len(report['unavailable']):3d}  {', '.join(sorted(report['unavailable'])) or '—'}")
    print(f"dropped     {len(report['dropped']):3d}  copied and unattested → the entry now reads 'not curated for redhat'")
    print(f"users       {report['users']:3d}  fourth axis filled")
    print(f"merged      {len(report['merged']):3d}  {', '.join(report['merged']) or '—'}")
    print(f"redhat fix  {len(report['redhat_fixed']):3d}  measured against the EL9 repos: "
          f"{', '.join(sorted(report['redhat_fixed'])) or '—'}")
    print(f"redhat n/a  {len(report['redhat_unpackaged']):3d}  not packaged for EL, path cleared: "
          f"{', '.join(sorted(report['redhat_unpackaged'])) or '—'}")
    print(f"debian fix  {len(report['debian_fixed']):3d}  {', '.join(sorted(report['debian_fixed'])) or '—'}")
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
