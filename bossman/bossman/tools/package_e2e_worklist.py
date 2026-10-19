"""Every package of both families, each with exactly ONE route by which it is configured — or a named reason why not.

    .venv-host/bin/python -m bossman.tools.package_e2e_worklist [--refresh-debian-paths]

THE QUESTION. "Is every available package configurable per rule or wizard?" is only answerable when every package
is classified, so this is the exhaustive classification the e2e runner then tests:

  wizard         a catalog role names the package for this family → the install-<role> runbook (preview/apply)
  rule-template  its primary /etc file is freeform and a template renders exactly that file (family-matched)
  rule-codec     its primary /etc file is parseable (keyvalue/ini/json/yaml/xml/…) → per-key `config` resource
  no-config      it ships no configuration file under /etc (only scripts, or nothing)
  replaced       the repository replaces it (Obsoletes, tools/rpm_replacements): installing it installs another
                 package, which has its own route — a route measured on this package names a file no host gets
  unrouted       it ships a configuration file, but no route reaches it — THE FINDING this list exists for

WHERE THE FILES COME FROM — measured, not guessed. RedHat: the universe's config_paths, read from the repos'
filelists.xml (rh_universe.py). Debian had no such list — its universe was filtered by archive SECTION — so
`--refresh-debian-paths` reads the archive's own Contents index (one download per component, the path → package
map of all of trixie) and writes config_paths into the Debian universe the same way, same field name.

The primary file is chosen by the SAME ranking the qualify pipeline uses (_pick_primary_config), so the file
tested is the file the pipeline templated.
"""

from __future__ import annotations

import argparse
import gzip
import re
import subprocess
from collections import Counter
from pathlib import Path

from bossman.services.template_gate import DirectorySet, plausible_target
from bossman.tools import qualify_packages as Q

WORKLIST = Q._CONFIGS / "package_e2e_worklist.json"
CONTENTS_DIR = Path("/data1/agentic-dev-tmp/contents")
CONTENTS_URL = "https://deb.debian.org/debian/dists/{suite}/{comp}/Contents-{arch}.gz"

#: Files under /etc that are not configuration a user edits — the same list rh_universe.py applies to RedHat, so a
#: package means the same thing in both families.
NOISE = re.compile(
    r"^/etc/(rc\d?\.d|init\.d/\.|pki/(ca-trust|rpm-gpg)|ssl/certs|"
    r"alternatives|systemd/system/[^/]*\.wants|udev/hwdb\.d|"
    r"[^/]*\.d/README|.*\.rpmnew|.*\.rpmsave)"
)
#: A file that is EXECUTED (init, cron run-parts, X session) — writing a rendered config over it replaces code.
SCRIPT = re.compile(
    r"^/etc/(init\.d|rc\d?\.d|cron\.(hourly|daily|weekly|monthly)|X11/Xsession\.d|profile\.d|sv|runit|grub\.d"
    r"|network/if-[a-z-]+\.d|ppp/ip-[a-z-]+\.d|kernel/[a-z-]+\.d|dhcp/dhclient-[a-z-]+-hooks\.d|NetworkManager/dispatcher\.d)/"
    r"|\.(sh|bash|py|pl)$"
)
PARSEABLE = {"keyvalue", "ini", "json", "yaml", "xml", "fstab", "zonefile", "exports", "dhcpd", "dirvalue"}


def refresh_debian_paths(suite: str = Q.DEB_SUITE, proxy: str = "") -> int:
    """Write `config_paths` into every Debian universe entry from the archive's Contents index."""
    CONTENTS_DIR.mkdir(parents=True, exist_ok=True)
    etc: dict[str, list[str]] = {}
    for comp in ("main", "contrib"):
        for arch in ("amd64", "all"):
            dest = CONTENTS_DIR / f"Contents-{comp}-{arch}.gz"
            if not dest.is_file():
                argv = ["curl", "-s", "-f", "-o", str(dest), CONTENTS_URL.format(suite=suite, comp=comp, arch=arch)]
                if proxy:
                    argv[1:1] = ["-x", proxy]
                subprocess.run(argv, check=True, timeout=900)
            with gzip.open(dest, "rt", errors="replace") as fh:
                for line in fh:
                    if not line.startswith("etc/"):
                        continue
                    path, _, owners = line.rstrip("\n").rpartition(" ")
                    path = "/" + path.strip()
                    for owner in owners.split(","):
                        pkg = owner.rsplit("/", 1)[-1]
                        etc.setdefault(pkg, []).append(path)
    universe = Q._load(Q.UNIVERSE, {})
    deb = universe.get("debian", {})
    for pkg, info in deb.items():
        info["config_paths"] = sorted(set(p for p in etc.get(pkg, []) if not NOISE.match(p)))
    Q._write_json(Q.UNIVERSE, universe, sort=False)
    return sum(1 for i in deb.values() if i["config_paths"])


def _template_targets() -> dict[str, dict[str, str]]:
    """path -> {template: family} over every template that records its target."""
    out: dict[str, dict[str, str]] = {}
    for d in Q.TEMPLATES_DIR.iterdir():
        meta = Q._load(d / "meta.json", {}) if d.is_dir() else {}
        if isinstance(meta, dict) and meta.get("target_path") and (d / "template.j2").is_file():
            out.setdefault(meta["target_path"], {})[d.name] = meta.get("family") or "debian"
    return out


def _template_for(path: str, family: str, targets: dict) -> str | None:
    """The template the index would offer a host of `family` for `path`: a family-matched one first, then a
    family-neutral (Debian-made) one — but for RedHat only if no RedHat template exists. Mirrors template_index."""
    cands = targets.get(path) or {}
    same = sorted(t for t, f in cands.items() if f == family)
    if same:
        return same[0]
    neutral = sorted(t for t, f in cands.items() if f == "debian")
    return neutral[0] if neutral else None


def classify(family: str, pkg: str, info: dict, catalog_by_pkg: dict, codecs: dict, targets: dict,
             known: DirectorySet | tuple = (), replaced: dict | None = None) -> dict:
    gone = (replaced or {}).get(pkg)
    if gone:
        return {"route": "replaced", "by": gone["by"],
                "reason": "installing it installs {} (Obsoletes: {}; the repository has {})".format(
                    gone["by"], gone["obsoletes"], gone["evr"])}
    paths = [p for p in info.get("config_paths") or [] if not NOISE.match(p)]
    # A DIRECTORY is no config file, whatever a package listing calls it: chkconfig and initscripts list /etc/init.d
    # (a symlink to rc.d/init.d in the RPM), the qualify pass gave it an `ini` codec, and the pod run failed with
    # "read /etc/init.d: is a directory" (measured 2026-10-15). Same rule as the template index (plausible_target):
    # a path another known path lies beneath is a directory.
    dirs = [p for p in paths if not plausible_target(p, known)] if known else []
    paths = [p for p in paths if p not in dirs]
    configs = [p for p in paths if not SCRIPT.match(p)]
    role = catalog_by_pkg.get(pkg)
    if role:
        name, branch, template = role
        path = branch.get("config_path") or ""
        row: dict = {"route": "wizard", "role": name}
        if not path and configs:
            # The role offers this package on this family but does not say which file it configures — the wizard
            # would render to an empty destination. Recorded as a finding; the measured file is tested instead.
            path = Q._pick_primary_config(configs, "", pkg) or configs[0]
            row["finding"] = f"catalog role {name!r} has no {family} config_path"
        # EXACTLY the engine's choice (nt_engine._apply_config_template), or the test checks a template the wizard
        # never renders: a template made for THIS family's file ("@<family>:<path>" — only non-Debian templates record
        # a family), else the role's own catalog template. Choosing by recorded target alone tested `network_manager`
        # for a role whose wizard renders another template.
        own = sorted(t for t, f in (targets.get(path) or {}).items() if f == family and f != "debian") if path else []
        row.update(path=path, template=own[0] if own else template, template_family_matched=bool(own))
        return row
    if not configs:
        reason = ("ships only scripts under /etc" if paths else
                  "ships only a directory under /etc ({})".format(", ".join(dirs[:3])) if dirs else
                  "ships nothing under /etc")
        return {"route": "no-config", "reason": reason}
    # The file the PIPELINE processed wins over a fresh pick: a bound template's target, then a codec entry that
    # names this package. Only without either does the ranking choose — the file tested must be the file that was
    # templated or classified, or a route is "missing" merely because two choosers disagreed.
    processed = [p for p in configs if p in targets] + [
        p for p in configs if pkg in ((codecs.get(p) or {}).get("packages") or [])]
    primary = processed[0] if processed else (Q._pick_primary_config(configs, "", pkg) or configs[0])
    codec = codecs.get(primary) or {}
    if codec.get("codec") in PARSEABLE:
        return {"route": "rule-codec", "path": primary,
                "codec": {k: codec.get(k) for k in ("codec", "separator", "comment") if codec.get(k) is not None}}
    tpl = _template_for(primary, family, targets)
    if tpl:
        return {"route": "rule-template", "path": primary, "template": tpl}
    why = "freeform file without a template" if codec.get("codec") == "none" else "file has no codec and no template"
    return {"route": "unrouted", "path": primary, "reason": why, "other_paths": configs[:8]}


def build() -> dict:
    universe = Q._load(Q.UNIVERSE, {})
    catalog = Q._load(Q.CATALOG, {})
    codecs = Q._load(Q.CODECS, {})
    targets = _template_targets()
    # Every path anyone records, so a directory shows itself by having a path beneath it.
    known = DirectorySet.of([p for p in codecs if isinstance(p, str)] + [
        p for fam in universe.values() if isinstance(fam, dict) for info in fam.values() if isinstance(info, dict)
        for p in info.get("config_paths") or [] if isinstance(p, str)])
    out: dict = {"families": {}, "summary": {}}
    for family in ("debian", "redhat"):
        catalog_by_pkg: dict[str, tuple] = {}
        for name, entry in catalog.items():
            branch = ((entry.get("families") or {}).get(family) or {}) if isinstance(entry, dict) else {}
            if branch.get("unavailable"):
                continue
            for pkg in branch.get("packages") or []:
                catalog_by_pkg.setdefault(pkg, (name, branch, entry.get("template")))
        replaced = (Q._load(Q._CONFIGS / "package_replacements.json", {}) or {}).get(family) or {}
        rows = {pkg: classify(family, pkg, info, catalog_by_pkg, codecs, targets, known, replaced)
                for pkg, info in sorted((universe.get(family) or {}).items())}
        out["families"][family] = rows
        out["summary"][family] = dict(Counter(r["route"] for r in rows.values()))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--refresh-debian-paths", action="store_true",
                    help="read the Debian Contents index and write config_paths into the Debian universe first")
    ap.add_argument("--proxy", default="")
    args = ap.parse_args()
    if args.refresh_debian_paths:
        n = refresh_debian_paths(proxy=args.proxy)
        print(f"debian universe: {n} packages ship a non-noise file under /etc", flush=True)
    wl = build()
    Q._write_json(WORKLIST, wl, sort=False)
    for family, summary in wl["summary"].items():
        total = sum(summary.values())
        print(f"{family}: {total} packages — " + ", ".join(f"{k} {v}" for k, v in sorted(summary.items())))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
