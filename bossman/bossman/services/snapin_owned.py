"""Which config files a dedicated Management snap-in owns — so two doors stop leading to one room.

THE FINDING (docs/logik-audit.md, 2026-08-19). 14 files are reachable BOTH through a purpose-built snap-in
and through the generic whole-file template editor, and the two are not equivalent:

    the snap-in knows the STRUCTURE — zones, shares, vhosts, printers, exports — and writes surgically
    the generic editor renders the WHOLE file from a flat form

So whichever door you take can overwrite what was done through the other, and nothing in the UI said which
one was in charge. That is two ways to one result, which the project's own rules call a logic error rather
than a matter of taste.

THE SPLIT IS BY FORMAT, not by preference:

  EXCLUSIVE — the file has structure the flat editor cannot represent. named.conf has zones, smb.conf has
  shares, nginx.conf has server blocks. Rendering it from a form loses whatever the form has no field for,
  so the template editor is not offered at all and the UI names the snap-in instead. Withholding an editor
  that would silently drop half a file is not a loss.

  ADVISORY — the file is flat, so the generic editor cannot destroy structure it failed to model.
  /etc/crontab and /etc/logrotate.conf stay editable both ways, and the UI simply says which snap-in also
  covers them. Here two doors are a convenience rather than a trap.

Deliberately a small hand-written table and not a derivation: "a snap-in exists for this" is a product
fact, known to the people who built the snap-ins, and inferring it from paths would be guessing at
something already known. It lives server-side because the path→template index is what has to carry the
answer out to the UI.
"""

from __future__ import annotations

#: path -> (snap-in id in the Management console, its label, exclusive?)
#:
#: The ids match host-management.component.ts, so the UI can deep-link straight to the right snap-in
#: (?tab=management&snapin=pkg-bind) rather than telling the operator to go and find it.
SNAPIN_OWNED: dict[str, tuple[str, str, bool]] = {
    # Structured formats — the snap-in is the only door.
    "/etc/bind/named.conf":            ("pkg-bind", "BIND zones", True),
    "/etc/bind/named.conf.local":      ("pkg-bind", "BIND zones", True),
    "/etc/bind/named.conf.options":    ("pkg-bind", "BIND zones", True),
    "/etc/exports":                    ("pkg-nfs", "NFS exports", True),
    "/etc/dhcp/dhcpd.conf":            ("pkg-dhcpd", "DHCP server", True),
    "/etc/samba/smb.conf":             ("pkg-samba", "Samba shares", True),
    "/etc/pure-ftpd/pure-ftpd.conf":   ("pkg-pureftpd", "Pure-FTPd", True),
    "/etc/proftpd/proftpd.conf":       ("pkg-proftpd", "ProFTPD", True),
    "/etc/cups/cupsd.conf":            ("pkg-cups", "CUPS printing", True),
    "/etc/nginx/nginx.conf":           ("pkg-nginx", "nginx sites", True),
    "/etc/apache2/apache2.conf":       ("pkg-apache", "Apache vhosts", True),
    "/etc/haproxy/haproxy.cfg":        ("pkg-haproxy", "HAProxy", True),
    "/etc/caddy/Caddyfile":            ("pkg-caddy", "Caddy", True),
    "/etc/traefik/traefik.yml":        ("pkg-traefik", "Traefik", True),
    # netplan is filled by the agent's interface module, not by a config template at all — and its paths
    # are globs, which the index already refuses. Listed so the next person does not add one.
    "/etc/network/interfaces":         ("network", "Network", True),

    # Flat formats — both doors, and the UI says so.
    "/etc/crontab":                    ("cron", "Scheduled jobs", False),
    "/etc/logrotate.conf":             ("logrotate", "Log rotation", False),
    "/etc/apt/sources.list":           ("apt-repos", "Software sources", False),
}


def snapin_for(path: str) -> tuple[str, str, bool] | None:
    """(snap-in id, label, exclusive) for a path a snap-in owns, else None."""
    return SNAPIN_OWNED.get(path)
