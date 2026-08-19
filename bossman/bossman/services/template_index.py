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

Glob paths are excluded on purpose. "/etc/php/*/fpm/pool.d/www.conf" identifies a SET of files; an
index entry claiming one template for a set would answer a question nobody asked.
"""

from __future__ import annotations

import json
import re
import time
from pathlib import Path

from bossman.services.template_gate import plausible_target, template_configures

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
                         templates_dir: str | Path) -> dict:
    """Return {"paths": {path: {"template": name, "source": "catalog"|"codec"}}, "conflicts": [...]}.

    Each input is passed explicitly rather than derived from a configs root: the codec registry has its
    own setting (`config_codecs_path`) and need not sit next to the catalog, and a function that guesses
    where its inputs live is a function that silently indexes the wrong ones.

    Pure and cheap (two file reads plus one directory listing). Missing or unreadable inputs yield an
    empty index rather than an error: no index means no Configure button, which is the safe direction —
    the alternative would be resolving by name again.
    """
    tpl_root, cat_p, cod_p = Path(templates_dir), Path(catalog_path), Path(codecs_path)
    key = (str(cat_p), str(cod_p), str(tpl_root))
    sig = _signature(cat_p, cod_p, tpl_root)
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

    known = {p for e in _load(codecs_path).values() if isinstance(e, dict)
             for p in (e.get("paths") or []) if isinstance(p, str)}

    # Source 1 — the catalog. First, so it owns every path it claims.
    for role, entry in _load(catalog_path).items():
        if not isinstance(entry, dict):
            continue
        tname = entry.get("template")
        cfg = ((entry.get("families") or {}).get("debian") or {}).get("config_path") or ""
        if not tname or not cfg or tname not in dirs or not plausible_target(cfg, known):
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
    for name in sorted(dirs):
        try:
            meta = json.loads((tpl_root / name / "meta.json").read_text())
        except (OSError, ValueError):
            continue
        p = meta.get("target_path") if isinstance(meta, dict) else None
        if not isinstance(p, str) or not plausible_target(p, known):
            continue
        have = paths.get(p)
        if have is None:
            paths[p] = {"template": name, "source": "template-meta"}
        elif have["template"] != name:
            conflicts.append({"path": p, "chosen": have["template"], "chosen_source": have["source"],
                              "also": name, "also_source": "template-meta"})

    result = {"paths": paths, "conflicts": conflicts}
    _CACHE[key] = (time.monotonic(), sig, result)
    return result
