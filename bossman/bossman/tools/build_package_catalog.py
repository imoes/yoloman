"""Block 0 (scaled) — build configs/package_catalog.json: the source of truth for
the installation wizard + Roles & Features snap-in. It is CODEC-DRIVEN: every
config file in the codec registry that has a config template becomes a catalog
entry (its package(s), config path, category), so "every package with a config"
gets a wizard/runbook. A small curated CORE table overrides the well-known
server roles with richer data (per-family package names, service unit,
validate_cmd, nice label/description); everything else is auto-derived.

    .venv/bin/python scripts/build_package_catalog.py
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))  # the dir holding the `bossman` package —
# correct in both layouts (unlike the configs path, which is why _paths exists)

from bossman.tools._paths import configs_dir, repo_root  # noqa: E402
from bossman.services.template_gate import template_configures  # noqa: E402

# FOUND, not counted — parents[2] is one level short in a checkout. See _paths.repo_root.
ROOT = repo_root(__file__)
# Configs root is env-overridable (AGENTIC_CONFIGS_DIR) so Bossman can run the
# catalog/categorization step in-container against the RW-mounted configs — same
# knob as qualify_packages.py.
_CONFIGS = configs_dir(__file__)
TEMPLATES_DIR = _CONFIGS / "config_templates"
CODECS = _CONFIGS / "config_codecs.json"
DEST = _CONFIGS / "package_catalog.json"


def _fam(packages, service, config_path):
    return {"packages": packages, "service": service, "config_path": config_path}


SEED = _CONFIGS / "package_seed.json"

#: /etc directories that hold a package's ANCILLARY files — a cron hook, a logrotate rule, a PAM
#: stanza. Every package ships some, and picking one as "the main config" sends Configure at the
#: wrong file. /etc/ufw/ is listed because ufw ships application profiles NAMED AFTER other
#: packages, so a basename match there is guaranteed to be wrong.
_ANCILLARY = ("/etc/cron.daily/", "/etc/cron.d/", "/etc/cron.hourly/", "/etc/cron.weekly/",
              "/etc/logrotate.d/", "/etc/init.d/", "/etc/default/", "/etc/rc.d/", "/etc/apparmor.d/",
              "/etc/pam.d/", "/etc/sysctl.d/", "/etc/modprobe.d/", "/etc/profile.d/",
              "/etc/ufw/")


#: Seed config_path claims REFUTED against the real Debian archive, with the refutation.
#:
#: The seed is a model enumeration and the codec registry can only witness that a path EXISTS, not
#: that it belongs to this package. Both agreed on /etc/crm/crm.conf for pacemaker; the archive says
#: otherwise, so the claim is recorded as refuted rather than argued about again next time.
#:
#: Checked on a Debian 13 host with `apt-get download` + `dpkg-deb -c` (no install). The other seven
#: seed-only claims SURVIVED that check, and how they survived is worth writing down, because a naive
#: "is it a conffile?" test rejects three of them:
#:   cron → /etc/crontab            shipped by cron-daemon-common, a dependency of cron
#:   openssh-server → sshd_config   ships /usr/share/openssh/sshd_config, installed via ucf
#:   sssd → /etc/sssd/sssd.conf     sssd-common owns /etc/sssd/; the file is admin-created
#:   ntpsec, rsyslog, sudo          real conffiles of the package itself
#:   mysql-server                   not downloadable on the test host — unverified, left as-is
#: So "not a conffile" is NOT evidence of a wrong path; "another package ships it" is.
_SEED_PATH_REFUTED: dict[str, str] = {
    "pacemaker": "/etc/crm/crm.conf is shipped by crmsh, not pacemaker (pacemaker's own state is the "
                 "CIB, not an /etc file)",
}


def _seed_packages() -> dict:
    """package_seed.json's package map, keyed with UNDERSCORES (the seed's own convention)."""
    try:
        return json.loads(SEED.read_text()).get("packages", {}) or {}
    except (OSError, ValueError):
        return {}


def main_config_path(pkg: str, codecs: dict, seed: dict | None = None) -> str:
    """The package's MAIN /etc config file — the ONE answer to that question.

    Empty when nothing qualifies. Empty is correct and not a failure: the wizard resolves the path
    from the installed package at runtime, whereas a confidently-wrong path makes Configure write a
    whole rendered file over the wrong target.

    TWO grounded sources. Neither is a guess, and the ORDER is the point:

      1. package_seed.json's config_path, accepted ONLY IF that exact path is a key in the codec
         registry. The seed is a model enumeration, so on its own it is a claim; the codec registry
         is built from Debian package metadata, so "this exact path is a real /etc config file we
         have a codec for" is an independent witness for it.

      2. THE CODEC REGISTRY alone, keyed by path and listing packages. Keep absolute /etc paths, drop
         the ancillary dirs, then require the package's stem as a real PATH COMPONENT — a directory
         right under /etc WITH something in it, or a <stem>.conf/<stem>d.conf basename. A bare
         basename match is deliberately not enough: it once picked /etc/ufw/applications.d/samba (a
         ufw profile file literally named "samba") over smb.conf.

    The seed goes FIRST because the two sources answer different questions. The seed claims "this is
    the package's MAIN config"; the registry can only say "this is SOME config file of that package".
    Measured on the disagreements: registry-first gave sudo → /etc/sudo.conf (the plugin config) where
    the seed says /etc/sudoers, and that is not a tie to be broken by luck — the seed is answering the
    question actually being asked.

    Why source 1 is needed at all: source 2's stem rule cannot see /etc/crontab for `cron`,
    /etc/sudoers for `sudo` or /etc/rsyslog.conf for `rsyslog` — no <stem>/ directory, and the
    basename is not <stem>.conf. Measured on the built catalog, 30 of 89 roles had an empty
    config_path and these two sources fill 15. That empty path is not cosmetic: it is what made the
    file picker template /etc/default/libvirtd (6 SysV variables) instead of
    /etc/libvirt/libvirtd.conf (17 kB).

    NOT used as a witness: the codec entry's own `packages` list. It is demonstrably incomplete —
    /etc/ssh/sshd_config lists `gesftpserver` and not `openssh-server` — so requiring membership
    there would reject 8 correct paths (sshd_config, /etc/crontab, /etc/sudoers, …) to guard against
    a mis-attribution that the path-existence check already makes unlikely.

    Shared by scripts/classify_roles_features.py (new rows) and scripts/curate_catalog.py (repairing
    rows an earlier run already wrote), so "what is this package's main config" has one definition.
    """
    if seed is None:
        seed = _seed_packages()
    entry = seed.get(pkg.replace("-", "_")) or {}
    claimed = ((entry.get("families") or {}).get("debian") or {}).get("config_path") or ""
    # The witness. Also refuse a path outside /etc (the seed offers ~/.config/containers/... for
    # podman — a per-user file, not a host config this catalog can manage) and the ancillary dirs, so
    # source 1 cannot smuggle in what source 2 rules out.
    if (claimed.startswith("/etc/") and claimed in codecs
            and pkg not in _SEED_PATH_REFUTED
            and not claimed.endswith("/")            # a trailing slash IS the directory marker
            and not any(claimed.startswith(a) for a in _ANCILLARY)):
        return claimed

    stem = pkg.replace("-server", "").split("-")[0]
    hits = [p for p, e in codecs.items()
            if isinstance(e, dict) and pkg in (e.get("packages") or [])
            and p.startswith("/etc/") and not any(p.startswith(a) for a in _ANCILLARY)]
    # `parts[2:3] == [stem]` alone matched /etc/restic — the stem WITH NOTHING AFTER IT, i.e. the
    # package's config DIRECTORY. config_path feeds template_render, which writes one whole file, so a
    # directory there is not a near miss but an unwritable target. The directory form therefore
    # requires a further segment; the file form is the explicit <stem>.conf/<stem>d.conf basename.
    named = [p for p in hits
             if not p.endswith("/")
             and ((p.split("/")[2:3] == [stem] and len(p.split("/")) > 3)
                  or p.rsplit("/", 1)[-1] in (f"{stem}.conf", f"{stem}d.conf"))]
    return named[0] if named else ""


def _template_configures(tname: str) -> bool | None:
    """Does this template actually configure the file its schema describes? True / False / None.

    A thin wrapper: the RULE lives in bossman.services.template_gate, because the server needs it too
    (the path→template index must not offer an editor the gate refuses — measured, 437 of 3488
    codec-sourced entries did) and the server cannot import scripts/. Read the reasoning there; this
    only supplies the templates directory, which scripts and tests monkeypatch as TEMPLATES_DIR.
    """
    return template_configures(TEMPLATES_DIR, tname)


# Curated rich overrides for the common server roles (per-family + service + validate).
CORE: dict[str, dict] = {
    "nginx": {"label": "NGINX Web Server", "category": "web", "icon": "language",
              "description": "High-performance HTTP server and reverse proxy.", "validate_cmd": "nginx -t",
              "families": {"debian": _fam(["nginx"], "nginx", "/etc/nginx/nginx.conf"),
                           "redhat": _fam(["nginx"], "nginx", "/etc/nginx/nginx.conf")}},
    "apache2": {"label": "Apache HTTP Server", "category": "web", "icon": "language",
                "description": "The Apache web server — HTTP/HTTPS and virtual hosts.", "validate_cmd": "apachectl configtest",
                "families": {"debian": _fam(["apache2"], "apache2", "/etc/apache2/apache2.conf"),
                             "redhat": _fam(["httpd"], "httpd", "/etc/httpd/conf/httpd.conf")}},
    "haproxy": {"label": "HAProxy Load Balancer", "category": "network", "icon": "hub",
                "description": "TCP/HTTP load balancer and proxy.", "validate_cmd": "haproxy -c -f /etc/haproxy/haproxy.cfg",
                "families": {"debian": _fam(["haproxy"], "haproxy", "/etc/haproxy/haproxy.cfg"),
                             "redhat": _fam(["haproxy"], "haproxy", "/etc/haproxy/haproxy.cfg")}},
    "caddy": {"label": "Caddy Web Server", "category": "web", "icon": "language",
              "description": "Simple HTTP/HTTPS server & reverse proxy with automatic HTTPS.",
              "validate_cmd": "caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile",
              "families": {"debian": _fam(["caddy"], "caddy", "/etc/caddy/Caddyfile"),
                           "redhat": _fam(["caddy"], "caddy", "/etc/caddy/Caddyfile")}},
    "traefik": {"label": "Traefik Proxy", "category": "network", "icon": "hub",
                "description": "Cloud-native edge router / reverse proxy (file provider).",
                "families": {"debian": _fam(["traefik"], "traefik", "/etc/traefik/traefik.yml"),
                             "redhat": _fam(["traefik"], "traefik", "/etc/traefik/traefik.yml")}},
    "adminer": {"label": "Adminer (DB admin)", "category": "database", "icon": "storage",
                "description": "Single-file database admin UI (MySQL/MariaDB/PostgreSQL), served via Apache.",
                "families": {"debian": _fam(["adminer"], "apache2", "/etc/apache2/conf-available/adminer.conf"),
                             "redhat": _fam(["adminer"], "httpd", "/etc/httpd/conf.d/adminer.conf")}},
    "redis": {"label": "Redis In-Memory Store", "category": "database", "icon": "memory",
              "description": "In-memory key-value store, cache and broker.",
              "families": {"debian": _fam(["redis-server"], "redis-server", "/etc/redis/redis.conf"),
                           "redhat": _fam(["redis"], "redis", "/etc/redis/redis.conf")}},
    "chrony": {"label": "Chrony NTP", "category": "time", "icon": "schedule",
               "description": "Network time synchronisation daemon.",
               "families": {"debian": _fam(["chrony"], "chrony", "/etc/chrony/chrony.conf"),
                            "redhat": _fam(["chrony"], "chronyd", "/etc/chrony.conf")}},
    "postfix": {"label": "Postfix Mail Server", "category": "network", "icon": "mail",
                "description": "Mail transfer agent (MTA).",
                "families": {"debian": _fam(["postfix"], "postfix", "/etc/postfix/main.cf"),
                             "redhat": _fam(["postfix"], "postfix", "/etc/postfix/main.cf")}},
    "postgresql": {"label": "PostgreSQL Database", "category": "database", "icon": "database",
                   "description": "Advanced open-source relational database.",
                   "families": {"debian": _fam(["postgresql"], "postgresql", "/etc/postgresql/*/main/postgresql.conf"),
                                "redhat": _fam(["postgresql-server"], "postgresql", "/var/lib/pgsql/data/postgresql.conf")}},
    "mariadb": {"label": "MariaDB / MySQL Database", "category": "database", "icon": "database",
                "description": "MariaDB/MySQL relational database server.",
                "families": {"debian": _fam(["mariadb-server"], "mariadb", "/etc/mysql/mariadb.conf.d/50-server.cnf"),
                             "redhat": _fam(["mariadb-server"], "mariadb", "/etc/my.cnf.d/mariadb-server.cnf")}},
    "sshd": {"label": "OpenSSH Server", "category": "security", "icon": "vpn_key",
             "description": "Secure Shell server. A bad setting can lock you out.", "validate_cmd": "sshd -t",
             "families": {"debian": _fam(["openssh-server"], "ssh", "/etc/ssh/sshd_config"),
                          "redhat": _fam(["openssh-server"], "sshd", "/etc/ssh/sshd_config")}},
    "php-fpm": {"label": "PHP-FPM", "category": "web", "icon": "code",
                "description": "PHP FastCGI Process Manager.",
                "families": {"debian": _fam(["php-fpm"], "php-fpm", "/etc/php/*/fpm/pool.d/www.conf"),
                             "redhat": _fam(["php-fpm"], "php-fpm", "/etc/php-fpm.d/www.conf")}},
    "docker-daemon": {"label": "Docker Engine", "category": "virtualization", "icon": "inventory_2",
                      "description": "Container runtime daemon (daemon.json).",
                      "families": {"debian": _fam(["docker-ce", "docker.io"], "docker", "/etc/docker/daemon.json"),
                                   "redhat": _fam(["docker-ce"], "docker", "/etc/docker/daemon.json")}},
    "fail2ban": {"label": "Fail2ban", "category": "security", "icon": "gpp_good",
                 "description": "Bans hosts with repeated auth failures via firewall rules.",
                 "families": {"debian": _fam(["fail2ban"], "fail2ban", "/etc/fail2ban/jail.local"),
                              "redhat": _fam(["fail2ban"], "fail2ban", "/etc/fail2ban/jail.local")}},
    "samba": {"label": "Samba File Sharing", "category": "network", "icon": "folder_shared",
              "description": "SMB/CIFS file and print sharing.", "validate_cmd": "testparm -s",
              "families": {"debian": _fam(["samba"], "smbd", "/etc/samba/smb.conf"),
                           "redhat": _fam(["samba"], "smb", "/etc/samba/smb.conf")}},
    # NFS: the single "NFS Server" role configures the *service* (/etc/nfs.conf,
    # keyed "nfs.conf" below). Exports (/etc/exports) are NOT a role — they are
    # managed in the NFS exports snap-in — so there is no nfs-exports entry here.
    "bind9": {"label": "BIND DNS Server", "category": "network", "icon": "dns",
              "description": "Authoritative/recursive DNS name server.", "validate_cmd": "named-checkconf /etc/bind/named.conf",
              "families": {"debian": _fam(["bind9"], "named", "/etc/bind/named.conf.options"),
                           "redhat": _fam(["bind"], "named", "/etc/named.conf")}},
    "dnsmasq": {"label": "dnsmasq", "category": "network", "icon": "dns",
                "description": "Lightweight DNS forwarder and DHCP server.", "validate_cmd": "dnsmasq --test",
                "families": {"debian": _fam(["dnsmasq"], "dnsmasq", "/etc/dnsmasq.conf"),
                             "redhat": _fam(["dnsmasq"], "dnsmasq", "/etc/dnsmasq.conf")}},
    "memcached": {"label": "Memcached", "category": "database", "icon": "memory",
                  "description": "Distributed in-memory object cache.",
                  "families": {"debian": _fam(["memcached"], "memcached", "/etc/memcached.conf"),
                               "redhat": _fam(["memcached"], "memcached", "/etc/sysconfig/memcached")}},
    "vsftpd": {"label": "vsftpd FTP Server", "category": "network", "icon": "cloud_upload",
               "description": "Very Secure FTP Daemon.",
               "families": {"debian": _fam(["vsftpd"], "vsftpd", "/etc/vsftpd.conf"),
                            "redhat": _fam(["vsftpd"], "vsftpd", "/etc/vsftpd/vsftpd.conf")}},
    "pure-ftpd": {"label": "Pure-FTPd Server", "category": "network", "icon": "drive_folder_upload",
                  "description": "Pure-FTPd file transfer server — global daemon settings. Virtual users are managed in the Pure-FTPd snap-in.",
                  "families": {"debian": _fam(["pure-ftpd"], "pure-ftpd", "/etc/pure-ftpd/pure-ftpd.conf"),
                               "redhat": _fam(["pure-ftpd"], "pure-ftpd", "/etc/pure-ftpd/pure-ftpd.conf")}},
    "proftpd": {"label": "ProFTPD Server", "category": "network", "icon": "drive_folder_upload",
                "description": "ProFTPD file transfer server — global daemon settings. Virtual users are managed in the ProFTPD snap-in.",
                "validate_cmd": "proftpd --configtest",
                "families": {"debian": _fam(["proftpd-basic"], "proftpd", "/etc/proftpd/proftpd.conf"),
                             "redhat": _fam(["proftpd"], "proftpd", "/etc/proftpd/proftpd.conf")}},
    "cups": {"label": "CUPS Print Server", "category": "network", "icon": "print",
             "description": "CUPS print server daemon (cupsd.conf) — listen/access/logging. Printers are managed in the CUPS snap-in.",
             "families": {"debian": _fam(["cups"], "cups", "/etc/cups/cupsd.conf"),
                          "redhat": _fam(["cups"], "cups", "/etc/cups/cupsd.conf")}},
    "nfs.conf": {"label": "NFS Server", "category": "network", "icon": "folder_shared",
                 "description": "NFS server service settings — threads, protocol versions, transports, grace/lease, fixed ports, Kerberos (/etc/nfs.conf). Exports are managed in the NFS exports snap-in.",
                 "families": {"debian": _fam(["nfs-kernel-server"], "nfs-server", "/etc/nfs.conf"),
                              "redhat": _fam(["nfs-utils"], "nfs-server", "/etc/nfs.conf")}},
}

TEMPLATE_ALIAS = {"mariadb": "mariadb", "sshd": "sshd", "php-fpm": "php-fpm",
                  "docker-daemon": "docker-daemon", "nfs-exports": "nfs-exports",
                  # The CORE role is named after the FUNCTION, the template after the PACKAGE the
                  # qualify pipeline processed. Without the alias the builder looks for a template
                  # dir called "iscsi-target", finds none, and writes template: null — the role
                  # reads as "no config yet" while /etc/tgt/targets.conf sits fully templated under
                  # config_templates/tgt.
                  "iscsi-target": "tgt",
                  # FOUR template dirs exist around sshd and three of them render a DIFFERENT file:
                  #   ssh             34 fields, renders ssh_config — the CLIENT config
                  #   sshd            90 sshd_config fields, body is /etc/pam.d/sshd (@include common-auth)
                  #   openssh-server   1 field,  body is a ufw application profile
                  #   sshd_config     31 fields, body starts `Port {{ port }}`  ← the only right one
                  # The role pointed at the ufw profile with config_path /etc/ssh/sshd_config, so
                  # Configure would have rendered five lines of firewall profile over the SSH daemon
                  # config and locked everyone out. Retargeted, not withdrawn: the correct template
                  # exists, so removing the editor would lose a working feature for no reason.
                  "openssh-server": "sshd_config",
                  # Same shape as openssh-server, found by clicking the button in the browser: the
                  # `chrony` template renders /etc/default/chrony (its own first line: "Chrony daemon
                  # options wrapper … passes runtime options to the service") while its schema lists 12
                  # chrony.conf directives, and the catalog aimed it at /etc/chrony/chrony.conf. It
                  # places 1 of those 12, so the placeholder rule does not catch it — a template can
                  # be parameterised and still describe the wrong file. config_templates/chrony.conf
                  # is the real one: 42 fields, 32 placed, header "Chrony Configuration Template".
                  "chrony": "chrony.conf"}

# Category by keyword in the config path (mirrors the UI's config-categories).
_CAT = [
    ("security", r"ssh|sudoers|pam|sssd|selinux|apparmor|fail2ban|firewall|ufw|opasswd|faillock|pwquality"),
    ("time", r"chrony|ntp|timesyncd|adjtime"),
    ("logging", r"rsyslog|syslog|journald|logrotate|audit"),
    ("network", r"network|resolv|hosts|netplan|interfaces|dnsmasq|named|bind|haproxy|nginx|apache|postfix|dovecot|samba|nfs|exports|vsftpd|dhcp"),
    ("database", r"mysql|maria|postgres|redis|memcached|mongo"),
    ("services", r"cron|anacron|systemd|init|service|logind"),
    ("storage", r"lvm|fstab|mdadm|multipath|smartd|hdparm|zfs"),
    ("web", r"php|apache|nginx|httpd"),
    ("virtualization", r"docker|libvirt|qemu|proxmox|lxc|containerd"),
]


def _category(path: str) -> str:
    p = path.lower()
    for cat, rx in _CAT:
        if re.search(rx, p):
            return cat
    return "system"


def _icon(cat: str) -> str:
    return {"security": "vpn_key", "time": "schedule", "logging": "article", "network": "lan",
            "database": "database", "services": "settings_applications", "storage": "storage",
            "web": "language", "virtualization": "inventory_2"}.get(cat, "description")


def _label(name: str) -> str:
    return re.sub(r"[._-]+", " ", name).strip().title()


def _template_name(codec_key: str) -> str:
    base = codec_key.rstrip("/").split("/")[-1]
    base = base.replace("*", "").strip(".") or codec_key.strip("/").replace("/", "-")
    return re.sub(r"[^A-Za-z0-9._-]", "-", base) or "config"


def main() -> int:
    catalog: dict[str, dict] = {}

    # 0) The enumerated cross-distro universe (configs/package_seed.json) — the
    #    broad set qwen listed for debian/ubuntu/redhat/suse. Included even
    #    without a template yet (shown in Roles & Features; the wizard's Configure
    #    step activates once the template lands).
    seed = _seed_packages()
    for key, entry in seed.items():
        tname = _template_name(key)
        # Only seeds whose template has actually been generated (and thus passed
        # the render gate) become roles — the raw enumeration contains
        # hallucinated package variants that would swamp the list.
        if not (TEMPLATES_DIR / tname).is_dir():
            continue
        cat = entry.get("category") or _category(key)
        catalog[key] = {
            "label": entry.get("label", _label(key)), "category": cat, "icon": _icon(cat),
            "description": entry.get("description", ""),
            "template": tname, "kind": "role",
            "families": entry.get("families", {}),
        }

    # 1) Auto entries from the codec registry — every codec file that has a
    #    template + at least one package becomes a configurable role.
    codecs = json.loads(CODECS.read_text()) if CODECS.is_file() else {}
    for key, entry in codecs.items():
        # Only clean, single-file basenames become installable roles — glob/path
        # keys (e.g. "/etc/mysql/conf.d/*") get a template for Configuration
        # coverage but are not meaningful "install this role" entries.
        if "*" in key or "/" in key:
            continue
        tname = _template_name(key)
        if not (TEMPLATES_DIR / tname).is_dir():
            continue
        pkgs = entry.get("packages") or []
        paths = entry.get("paths") or []
        config_path = next((p for p in paths if "*" not in p), paths[0] if paths else key)
        if not pkgs:
            continue
        cat = _category(config_path + " " + tname)
        catalog[tname] = {
            "label": _label(tname), "category": cat, "icon": _icon(cat),
            "description": f"Configure {tname} (provided by {', '.join(pkgs[:3])}).",
            # kind=config: a base-system config file (adduser.conf, sysctl.conf,
            # …) reachable via the Configuration/gpedit tab — NOT an installable
            # server role, so it stays out of Roles & Features + the Add wizard.
            "template": tname, "kind": "config",
            # debian only: `pkgs` comes from the codec registry, which is built from Debian
            # package metadata. Emitting a redhat branch here (as this line used to) copies a
            # Debian name into a family nobody checked — see classify_roles_features._catalog_entry
            # for the same defect and the measurement. A missing branch is resolved by
            # package_wizard as an explicit fallback; a fabricated one is not resolvable at all.
            "families": {"debian": _fam(pkgs, "", config_path)},
        }

    # 2) Curated CORE overrides (richer: per-family packages/service/validate).
    for name, entry in CORE.items():
        tname = TEMPLATE_ALIAS.get(name, name)
        has_tpl = (TEMPLATES_DIR / tname).is_dir()
        catalog[name] = {**entry, "template": tname if has_tpl else None, "kind": "role"}

    # 3) Dedup: drop auto entries that duplicate a curated/seed role — same
    #    template claimed twice (e.g. codec "chrony.conf" next to CORE "chrony")
    #    reads as two confusing rows in Roles & Features.
    core_templates = {e["template"] for k, e in catalog.items() if k in CORE and e["template"]}
    for key in [k for k, e in catalog.items()
                if k not in CORE and e.get("template") and (
                    e["template"] in core_templates
                    or e["template"].removesuffix(".conf") in catalog and e["template"].removesuffix(".conf") != key)]:
        del catalog[key]

    # 4) ADDITIVE MERGE: preserve entries this deterministic build does NOT
    #    regenerate — the roles/features the classify step (classify_roles_features
    #    / the on-demand categorize endpoint) added from tasksel/comps. This build
    #    only knows CORE + template-matched names; without this merge, running it
    #    (e.g. the categorize endpoint calls it) OVERWRITES the whole file and the
    #    classified server packages silently vanish — which is exactly how ~44
    #    entries (openssh-server, isc-dhcp-server, dovecot, prometheus, …) were
    #    lost once. setdefault: the fresh build wins for names it produces; any
    #    pre-existing name it doesn't produce survives.
    preserved = 0
    if DEST.exists():
        try:
            existing = json.loads(DEST.read_text())
            if isinstance(existing, dict):
                for name, entry in existing.items():
                    if name not in catalog and isinstance(entry, dict):
                        catalog[name] = entry
                        preserved += 1
        except (ValueError, OSError):
            pass

    # 5) A template that configures nothing must not offer Configure.
    #
    # `template` drives the wizard's Configure step, whose write path is template_render: WHOLE
    # FILE, to config_path. Measured on the built catalog, 7 of 90 templates mentioned not one of
    # their own schema's field names, because the batch had harvested the wrong file out of the
    # .deb — sshd's "template" is /etc/pam.d/sshd, aimed at /etc/ssh/sshd_config. Applying that
    # locks you out of the host. Withdrawing the action is not a loss: `template: None` already has
    # an honest rendering in the UI, and the four of those seven whose path has a codec stay
    # editable through the Configuration tab's per-key merge. See scripts/curate_catalog.py, which
    # applies the same rule to a catalog this build did not regenerate.
    withdrawn = []
    for name, entry in catalog.items():
        if entry.get("template") and _template_configures(entry["template"]) is False:
            entry["template"] = None
            withdrawn.append(name)

    DEST.write_text(json.dumps(catalog, indent=2, sort_keys=True) + "\n")
    if withdrawn:
        print(f"  {len(withdrawn)} template(s) withdrawn (do not configure their own file): "
              + ", ".join(sorted(withdrawn)))
    with_tpl = sum(1 for e in catalog.values() if e["template"])
    print(f"wrote {DEST} ({len(catalog)} packages, {with_tpl} with a template, "
          f"{preserved} classified entries preserved)")

    # THE SECOND HALF OF THE SAME OPERATION, not an optional extra pass.
    #
    # This build regenerates every entry from the generators, and the generators do not know the checked
    # RedHat facts — so a rebuild on its own STRIPS them. Measured on a real run: 24 entries lost their
    # curation, `apache2` lost the second package `httpd-core` and both `user` fields, and `adminer`'s
    # intentionally EMPTY redhat config_path (shipped by nothing, and saying so is the point) was replaced
    # by a guessed /etc/httpd/conf.d/adminer.conf.
    #
    # It used to be a separate script invoked after this one by the batch supervisor — so the batch was
    # right and the on-demand qualify endpoint, which called only this builder, silently de-curated the
    # catalog on every request. Two steps that must always both run are one operation; leaving the caller
    # to remember the second is how one caller forgets.
    #
    # Imported here rather than at module scope: curate_catalog imports THIS module for the single
    # definition of "does this template configure its own file", and at module scope that is a cycle.
    from bossman.tools import curate_catalog

    print("\n-- curation (checked RedHat branches, users, path witnesses) --")
    return curate_catalog.run()


if __name__ == "__main__":
    sys.exit(main())
