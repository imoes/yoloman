"""path → config template: the explicit index that replaces a basename guess.

WHY THIS EXISTS. The UI used to answer "does this config file have a template?" by taking the path's
basename minus .conf and looking for a template directory of that name. That is a guess from name
similarity, and it was measurably wrong: /etc/aardvark-dns/aardvark-dns.conf resolved to the template
dir `aardvark-dns`, which renders /etc/aardvark-dns/FORWARD.conf — a different file of the same
package. Since the Configure write path is template_render (WHOLE FILE, no merge), the "Edit via
template" button would have written one file's content over another.

It also made the host page download GET /config-templates in full — 33.7 MB of template bodies across
5460 directories — to perform a string comparison. This index is a few hundred kB of path→name pairs.

THREE GROUNDED SOURCES, and the precedence is deliberate:

  1. package_catalog.json — a role's own `template` together with its `families.debian.config_path`.
     Curated or measured, and the only one the withdrawal rule has been applied to, so a template known
     NOT to configure its own file is already `null` here. 55 paths.

  2. config_codecs.json — every non-glob path of a codec entry whose derived template dir exists. The
     template's name and the file's basename agree by construction here, which is direct evidence.

  3. the template's own meta.json `target_path` — a RECORDED fact rather than a derivation, written by
     scripts/backfill_template_target.py. It exists because the library and the resolver disagree about
     what a directory NAME means: the batch names a directory after the PACKAGE it processed, while this
     index resolves by FILE. Measured before it: 2786 of 5460 template dirs were unreachable by anything,
     2071 of them simply because no codec key's basename matched their name.

Source 1 wins where they disagree — measured 20 times, e.g. /etc/haproxy/haproxy.cfg where the role
offers `haproxy` and the codec key offers `haproxy.cfg`. BOTH DIRS EXIST: that is two templates for one
file, the same duplication as the 278 underscore/hyphen twin dirs on a different axis. The index does
not hide it — `conflicts` reports every case, because a resolution nobody can see is indistinguishable
from a coincidence.

AND A BINDING WHOSE PATH DOES NOT EXIST IS WITHDRAWN, reported in `withdrawn` rather than dropped. The
registry says how a file is written, never whether there is one: bindings named a path the package ships
nothing at, because the path was derived from the package NAME (/etc/aide, /etc/bind, /etc/ttygif). Configure
writes the whole file, so pressing it would create a new file in /etc that looks configured and that no
software reads. Measured per path by scripts/verify_registry_paths.py.

A verdict only withdraws when the CORPUS also has no file at that path (`exists_elsewhere`). The measurement
ran on Debian, and "absent from this package on this distro" is not "no such file": /etc/named.conf is absent
from Debian's bind9 and present on EL. 0 of 1920 name-derived absences appear in the corpus; 51 of 494 real
config-path absences do.

Glob paths are excluded on purpose. "/etc/php/*/fpm/pool.d/www.conf" identifies a SET of files; an
index entry claiming one template for a set would answer a question nobody asked.
"""

from __future__ import annotations

import json
import re
import time
from pathlib import Path

from bossman.services.snapin_owned import SNAPIN_OWNED as SNAPIN_ONLY_PATHS, snapin_for
from bossman.services.template_gate import DirectorySet, plausible_target, template_configures

#: Same normalisation the catalog builder uses for a template directory name, so the index cannot
#: disagree with the thing it indexes. Kept here rather than imported: scripts/ is not on the server's
#: import path, and one small regex duplicated is cheaper than a sys.path hack in a request handler.
_SAFE = re.compile(r"[^A-Za-z0-9._-]")


def _template_name(key: str) -> str:
    base = key.rsplit("/", 1)[-1] or key
    return _SAFE.sub("-", base) or "config"


#: In-process cache: {(catalog, codecs, templates_dir): (built_at, signature, index)}.
#:
#: Gating every entry means reading 5460 template bodies and schemas, which took the build from 41 ms to
#: 560 ms — and this endpoint sits in the host page's load path. The signature covers the two JSON inputs
#: (mtime + size) and the template root's own mtime and entry count, so adding, removing or rewriting a
#: catalog/codec file is picked up at once.
#:
#: The TTL is the honest part: editing a template.j2 IN PLACE changes neither the root dir's mtime nor
#: its entry count, so that one change is invisible to the signature. 60 seconds bounds how long a
#: freshly-broken template can still be offered, or a freshly-fixed one stay hidden. The batch that
#: writes templates runs for hours, so a minute is noise there; a page load is not.
_CACHE: dict[tuple, tuple[float, tuple, dict]] = {}
_TTL_SECONDS = 60.0


def _signature(catalog_path: Path, codecs_path: Path, tpl_root: Path) -> tuple:
    def _stat(p: Path) -> tuple:
        try:
            st = p.stat()
            return (st.st_mtime_ns, st.st_size)
        except OSError:
            return (0, 0)

    try:
        count = sum(1 for _ in tpl_root.iterdir())
    except OSError:
        count = -1
    return (_stat(catalog_path), _stat(codecs_path), _stat(tpl_root), count)


def build_template_index(catalog_path: str | Path, codecs_path: str | Path,
                         templates_dir: str | Path, family: str = "",
                         verdicts_path: str | Path | None = None) -> dict:
    """Return {"paths": {path: {"template": name, "source": "catalog"|"codec"}}, "conflicts": [...]}.

    Each input is passed explicitly rather than derived from a configs root: the codec registry has its
    own setting (`config_codecs_path`) and need not sit next to the catalog, and a function that guesses
    where its inputs live is a function that silently indexes the wrong ones.

    Pure and cheap (two file reads plus one directory listing). Missing or unreadable inputs yield an
    empty index rather than an error: no index means no Configure button, which is the safe direction —
    the alternative would be resolving by name again.
    """
    tpl_root, cat_p, cod_p = Path(templates_dir), Path(catalog_path), Path(codecs_path)
    ver_p = Path(verdicts_path) if verdicts_path else cat_p.parent / "config_path_verdicts.json"
    key = (str(cat_p), str(cod_p), str(tpl_root), family, str(ver_p))
    sig = _signature(cat_p, cod_p, tpl_root) + _signature(ver_p, ver_p, tpl_root)[:1]
    hit = _CACHE.get(key)
    if hit and hit[1] == sig and time.monotonic() - hit[0] < _TTL_SECONDS:
        return hit[2]

    dirs = {d.name for d in tpl_root.iterdir() if d.is_dir()} if tpl_root.is_dir() else set()
    # EVERY entry passes the gate, both sources. Source 1 is filtered upstream too (a withdrawn
    # template is already `null` in the catalog), but source 2 had NO filter at all: measured, 437 of
    # 3488 codec-sourced paths pointed at a template the gate refuses — shell scripts, ufw profiles,
    # unparameterised texts. Each one offered "Edit via template" on a file whose Apply writes a fixed
    # text over the live config. False is refused; None (cannot be judged) is kept, because withholding
    # every unjudgeable editor would remove working ones, and that asymmetry is the gate's own.
    ok = {name: template_configures(tpl_root, name) is not False for name in dirs}
    dirs = {name for name in dirs if ok[name]}

    def _load(path: str | Path) -> dict:
        try:
            data = json.loads(Path(path).read_text())
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    paths: dict[str, dict] = {}
    conflicts: list[dict] = []

    # Every template's OWN record, read once and shared by all three sources below. Source 3 used to read
    # these files itself; sources 1 and 2 never asked, which is exactly how the index came to contradict its
    # own artifacts.
    metas: dict[str, dict] = {}
    for name in sorted(dirs):
        try:
            data = json.loads((tpl_root / name / "meta.json").read_text())
        except (OSError, ValueError):
            continue
        if isinstance(data, dict):
            metas[name] = data

    def renders(name: str, path: str) -> bool:
        """Would binding `name` to `path` contradict what that template says about itself?

        MEASURED on the live index: 203 of 3611 bindings named a template whose own meta.json records a
        DIFFERENT target_path. /etc/ansible/hosts was bound to the template `hosts`, which records
        /etc/hosts — pressing Configure would have written the machine's hosts file over an Ansible
        inventory. /etc/cups/cupsd.conf was bound to `cups`, whose template.j2 is cups' snmp.conf, while
        `cups-redhat` (witness: rpm) records cupsd.conf exactly.

        Sources 1 and 2 bind by NAME — a catalog role name or a codec key that happens to match a directory.
        A name match is a hypothesis; `target_path` is a record. Where the two disagree the record wins, and
        the name-based binding is refused so the path stays free for whoever really claims it. A template
        with no record is not refused: most of the library predates the field, and refusing everything
        unrecorded would empty the index.
        """
        own = metas.get(name, {}).get("target_path")
        return not isinstance(own, str) or own == path

    # Precomputed ONCE: plausible_target asks "is this a directory", which is membership in the set of
    # ancestors of every known path. Asked as a linear scan per candidate it cost this endpoint 4.1 s after the
    # registry grew to 11573 entries — and it is in the host page's load path.
    known = DirectorySet.of(
        p for e in _load(codecs_path).values() if isinstance(e, dict)
        for p in (e.get("paths") or []) if isinstance(p, str))

    # Source 1 — the catalog. First, so it owns every path it claims.
    for role, entry in _load(catalog_path).items():
        if not isinstance(entry, dict):
            continue
        tname = entry.get("template")
        cfg = ((entry.get("families") or {}).get("debian") or {}).get("config_path") or ""
        if not tname or not cfg or tname not in dirs or not plausible_target(cfg, known):
            continue
        if not renders(tname, cfg):
            conflicts.append({"path": cfg, "chosen": None, "chosen_source": "catalog",
                              "also": tname, "also_source": "catalog",
                              "reason": "refused: template {} records target {}".format(
                                  tname, metas[tname]["target_path"])})
            continue
        paths.setdefault(cfg, {"template": tname, "source": "catalog", "role": role})

    # Every candidate path is checked by ONE rule (template_gate.plausible_target): under /etc, not a
    # glob, not an ancillary location, not a directory. The audit found three paths in the index that no
    # renderer could ever write — /etc/bind and /etc/ovn-controller-vtep (directories, with their real
    # config files sitting right beside them in the same registry) and /etc/default/policyd-weight (a
    # SysV defaults snippet). The resolver had always refused those; this source never asked.
    # Source 2 — the codec registry, as the fallback.
    #
    # NOT named `key`: that is the cache key three lines up, and shadowing it stored the result under
    # the last codec entry's name instead. The cache then never hit, which the timing showed (three
    # calls, 520 ms each) and reading would not have.
    for codec_key, entry in _load(codecs_path).items():
        if not isinstance(entry, dict):
            continue
        tname = _template_name(codec_key)
        if tname not in dirs:
            continue
        for p in entry.get("paths") or []:
            if not isinstance(p, str) or not plausible_target(p, known):
                continue
            if not renders(tname, p):
                conflicts.append({"path": p, "chosen": None, "chosen_source": "codec",
                                  "also": tname, "also_source": "codec",
                                  "reason": "refused: template {} records target {}".format(
                                      tname, metas[tname]["target_path"])})
                continue
            have = paths.get(p)
            if have is None:
                paths[p] = {"template": tname, "source": "codec"}
            elif have["template"] != tname:
                # Reported, never silently merged: two template dirs render the same file, and which
                # one is right is a question about their CONTENT, not something precedence settles.
                conflicts.append({"path": p, "chosen": have["template"], "chosen_source": have["source"],
                                  "also": tname, "also_source": "codec"})

    # Source 3 — the template's OWN record of what it renders (meta.json target_path), written by
    # scripts/backfill_template_target.py and, going forward, by the pipeline that generates the
    # template. Third in precedence because the catalog and the registry are the curated statements;
    # this one exists because a template directory is named after a PACKAGE while the index resolves by
    # FILE, so more than half the library — 2786 of 5460 dirs — was unreachable by anything.
    #
    # A recorded fact, not a derivation: the file says which path it is for, so nothing here has to
    # guess from the name. Directories whose target is AMBIGUOUS carry `ambiguous_with` and no
    # target_path (190 paths are claimed by 509 templates — 21 ejabberd modules all configure sections
    # of one ejabberd.yml), and they are skipped exactly because they were not resolved.
    for name, meta in sorted(metas.items()):
        p = meta.get("target_path")
        if not isinstance(p, str) or not plausible_target(p, known):
            continue
        have = paths.get(p)
        if have is None:
            # `family` only when the template records one — an empty key on every entry would be noise, and
            # the comparison below reads a missing key as "no family" anyway.
            paths[p] = {"template": name, "source": "template-meta"}
            if meta.get("family"):
                paths[p]["family"] = meta["family"]
        elif have["template"] != name:
            # SAME PATH, TWO DISTRIBUTIONS. /etc/caddy/Caddyfile is that path on both families and the two
            # files differ, so precedence alone would render Debian's over a RedHat host's. When the CALLER
            # knows the family — only a host does; this index is otherwise host-independent by design — the
            # matching template wins and the loser is still reported. Without a family, nothing changes: the
            # earlier claim stands and the clash is a conflict, which is the honest answer to a question
            # nobody has asked precisely enough.
            mine = meta.get("family") or ""
            # A RECORD BEATS A NAME. The incumbent came from source 1 or 2, which bind because a catalog role
            # or a codec key happens to share a directory name; this template states its target and carries
            # a witness for it (`deb`/`rpm` = read out of the package, `corpus-text` = its literal text was
            # matched against the shipped file). Measured: 265 paths were held by a name binding while a
            # witnessed record for the exact path sat unused — /etc/collectd.conf went to the Debian dir
            # `collectd.conf`, which shares 0% of EL's 988-line collectd.conf, while `collectd` matches it.
            # A record that declares a FAMILY is not used to override without one being asked for: that is
            # the /etc/caddy/Caddyfile case, where overriding blind would hand a Debian host EL's file.
            witnessed = meta.get("witness") in ("deb", "rpm", "corpus-text")
            incumbent_recorded = isinstance(metas.get(have["template"], {}).get("target_path"), str)
            if witnessed and not incumbent_recorded and (not mine or mine == family):
                conflicts.append({"path": p, "chosen": name, "chosen_source": "template-meta",
                                  "also": have["template"], "also_source": have["source"],
                                  "reason": "recorded target (witness {}) beats a name binding".format(
                                      meta.get("witness"))})
                paths[p] = {"template": name, "source": "template-meta"}
                if mine:
                    paths[p]["family"] = mine
            elif family and mine == family and have.get("family") != family:
                conflicts.append({"path": p, "chosen": name, "chosen_source": "template-meta",
                                  "also": have["template"], "also_source": have["source"],
                                  "reason": "family {} matches the host".format(family)})
                paths[p] = {"template": name, "source": "template-meta", "family": mine}
            else:
                conflicts.append({"path": p, "chosen": have["template"], "chosen_source": have["source"],
                                  "also": name, "also_source": "template-meta"})

    # A snap-in that owns the file gets the last word. EXCLUSIVE means the generic whole-file editor is not
    # offered for that path at all — named.conf has zones, smb.conf has shares, nginx.conf has server
    # blocks, and rendering any of them from a flat form drops whatever the form has no field for. The
    # entry stays in the index rather than disappearing: the UI needs to say WHICH snap-in is in charge,
    # and a path that silently vanished would look like "no editor exists".
    for path, entry in paths.items():
        owned = snapin_for(path)
        if owned:
            entry["snapin"], entry["snapin_label"], entry["snapin_exclusive"] = owned
    # The ownership table is returned SEPARATELY rather than injected into `paths`. My first version added
    # an entry per owned path with `template: null`, which made `paths` mean two things at once — "the
    # template that renders this file" and "a snap-in owns this file, no template involved" — and nine
    # tests said so immediately by finding paths in an index built from empty fixtures. One key, one
    # meaning: `paths` is templates, `snapins` is ownership, and an entry in `paths` carries the ownership
    # annotation when both apply.
    snapins = {path: {"snapin": o[0], "snapin_label": o[1], "snapin_exclusive": o[2]}
               for path, o in ((p, snapin_for(p)) for p in SNAPIN_ONLY_PATHS) if o}

    # A BINDING TO A PATH NOTHING SHIPS IS WITHDRAWN. Measured by extracting the real packages
    # (scripts/verify_registry_paths.py): of 3563 bindings, 1562 named a path that does not exist as a file.
    # This matters more here than anywhere else, because Configure writes the WHOLE file — pressing it would
    # CREATE /etc/aide (a directory in the package; the real config is /etc/aide.conf) and fill it with a
    # rendered text no software reads. Not a cosmetic wrong answer: a new file, in /etc, that looks
    # configured and is inert.
    #
    # THREE VERDICTS WITHDRAW, and one deliberately does not:
    #   directory / dangling-symlink   there is something there and it is not a writable file
    #   absent WITHOUT a maintainer script naming it   nothing accounts for this path at all
    #   absent WITH one                KEPT: a config created at install time is a real file on a real
    #                                  host, merely missing from the archive.
    # Unmeasured paths are also kept — absence of a measurement is not a measurement of absence, and
    # withdrawing everything unproven would remove thousands of working editors.
    verdicts = _load(ver_p)
    # THE SECOND GUARD: files no package owns because the SYSTEM creates them. Measured by asking the package
    # manager itself in a base image (scripts/find_unowned_base_files.py): 34 of debian:12's 106 /etc files
    # belong to no package — /etc/hostname, /etc/fstab, /etc/passwd, /etc/shells, /etc/timezone,
    # /etc/nsswitch.conf, the pam.d/common-* stack. Every one is a real, editable config on every host, and
    # every one gets an "absent" verdict because no archive contains it. Without this, the withdrawal removed
    # the editor for the machine's own hostname.
    unowned = _load(ver_p.parent / "config_unowned_paths.json")
    withdrawn = []
    for path in sorted(paths):
        seen = verdicts.get(path)
        if not isinstance(seen, dict):
            continue
        # THE FAMILY'S OWN MEASUREMENT WINS when this index is being built for a family, exactly as
        # /config-fields prefers the codec's by_family branch. Of 83 paths measured on both distributions 20
        # disagree — /etc/named.conf is absent from Debian's bind9 and a real file on EL — so a single answer
        # is wrong for one of them. The top level is the conservative aggregate (any family that found a file
        # makes it "file"), which is the right default for the host-independent base index.
        branch = (seen.get("by_family") or {}).get(family) if family else None
        measured_here = isinstance(branch, dict) and bool(branch.get("verdict"))
        if measured_here:
            seen = {**seen, **branch}
        verdict = seen.get("verdict")
        # THE FALSIFICATION POINT. A verdict is evidence about ONE package on ONE distribution, and the
        # measurement ran in a debian:12 container. `exists_elsewhere` says the corpus has real text at this
        # path, so the file demonstrably exists — under another package, or on the other distro.
        # /etc/named.conf is absent from Debian's bind9 (Debian puts it in /etc/bind/) and /etc/openldap/
        # ldap.conf is EL's location for Debian's /etc/ldap/ldap.conf. Measured: 0 of 1920 absent verdicts for
        # NAME-DERIVED paths appear in the corpus, but 51 of 494 from the real-config-path run do. Without this
        # guard those 51 editors would have been withdrawn for files that are on every host.
        # ...and it applies ONLY where this family was not measured directly. It was always a proxy for "we do
        # not know which distribution this host is", and where the branch above answers, we do. On a Debian
        # host /etc/named.conf really is not there — Debian's bind9 reads /etc/bind/named.conf — so offering
        # Configure would create a file the daemon ignores. The corpus proving it exists ON EL is not a reason
        # to offer it HERE.
        if seen.get("exists_elsewhere") and not measured_here:
            continue
        # THE VERDICT MUST BE ABOUT THIS PATH. It answers "does package P contain X", so when P is not the
        # package that ships X the answer is true about P and says nothing about X. Measured: 72 of 79
        # non-file verdicts whose path is in the corpus name the wrong package — /etc/os-release was measured
        # in `distrobox` (it belongs to base-files), /etc/crontab in `cronie` (crontabs). A direct measurement
        # of the wrong subject is not evidence, so it must not beat the corpus.
        shipped_by = seen.get("shipped_by")
        if isinstance(shipped_by, list) and shipped_by and seen.get("package") not in shipped_by:
            continue
        owner = unowned.get(path)
        if isinstance(owner, dict) and not owner.get("container_artifact"):
            continue
        if verdict == "not-a-path":
            continue      # the key is a basename; nothing was measured about a file
        if verdict in ("directory", "dangling-symlink") or (
                verdict == "absent" and not seen.get("postinst_mentions")):
            entry = paths.pop(path)
            # NOTHING VANISHES SILENTLY: the withdrawal is reported with its template, its reason and the
            # package it was measured in, exactly like `conflicts`. A binding that just disappeared would be
            # indistinguishable from one that never existed, and the next batch run would recreate it.
            withdrawn.append({"path": path, "template": entry.get("template"),
                              "source": entry.get("source"), "verdict": verdict,
                              "package": seen.get("package"),
                              "reason": "package {} ships no file at this path ({}, measured on {}) and no "
                                        "harvested package ships one either; Configure writes the whole "
                                        "file, so it would create one nothing reads".format(
                                            seen.get("package"), verdict,
                                            seen.get("family") or "debian")})

    result = {"paths": paths, "conflicts": conflicts, "snapins": snapins, "withdrawn": withdrawn}
    _CACHE[key] = (time.monotonic(), sig, result)
    return result
