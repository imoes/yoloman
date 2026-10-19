"""Stage 5: does every REACHABLE template, rendered with its own defaults, reproduce the file its package ships?

    .venv-host/bin/python -m bossman.tools.template_shipped_fidelity [--only a,b] [--family debian|redhat]
                                                                     [--redo] [--limit N] [--summary]

WHY. The pipeline's promise is that applying a role or a config template with nothing set changes nothing: the
defaults ARE the shipped file. Stages 1–4 prove that a template renders, is written, is accepted by the checker
and keeps the daemon up. None of them proves the defaults are the package's — a template whose defaults turn on a
documented example, or drop a section, passes all four and still changes the host on its first apply. Until now that
was measured one template at a time (~100). This measures every reachable one.

THE UNIT is what a request can actually name: (template, family, path), resolved the way the runtime resolves it —
  - the template index binds a path to a template, per family (config_template_index.json, families.<f>.paths);
  - a catalog role names a template and, per family, the config_path it renders;
  - a FAMILY template (meta.json family + target_path) wins for that family and path (nt_engine's `@<family>:<path>`).
So a Debian template that the index also binds on AlmaLinux is compared with the RPM's file too.

THE RENDER is the agent's own engine (cmd/render-check → internal/modules.TemplateRender, gonja), with the values the
wizard sends for an untouched role: the schema defaults, nulls left out, dotted keys nested (nt_engine._nest_dotted).

THE SHIPPED FILE comes from the package itself, downloaded and unpacked, never installed: Debian through the isolated
trixie apt of qualify_packages, AlmaLinux through rpm_source's container. Packages tried, in order: meta.json
`package`, the catalog role's packages for that family, the packages the universe records for that path, the
template's own name. When the package does not carry the path but carries exactly ONE file of the same basename
elsewhere (Debian ships many under /usr/share/<pkg>/ and a postinst copies them), that file is compared and named.

VERDICTS, exhaustive, one per unit, in configs/template_shipped_fidelity.json:
  identical        rendered == shipped, byte for byte
  same-settings    not byte-identical, but the active lines (not blank, not a comment) are the same multiset after
                   collapsing whitespace — comments or spacing differ, the configuration does not
  differs          the active lines differ; the lines only in the render and only in the file are recorded (first 8)
  no-shipped-file  a candidate package was fetched, none carries the file (generated at install time, or by a
                   postinst, or the wrong package) — the packages tried are named
  no-package       no candidate package could be fetched — the reasons are named
  does-not-render  render-check refuses the template with its defaults — its error is recorded
  no-target        the template is reachable but nothing names a concrete file for it (a pattern path is not one)
Resumable: a unit with a verdict is not redone unless --redo.
"""

from __future__ import annotations

import argparse
import collections
import json
import re
import runpy
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

from bossman.services.nt_engine import _nest_dotted
from bossman.services.schema_defaults import schema_defaults
from bossman.tools import qualify_packages as Q

REPO = Q._CONFIGS.parent
CONFIGS = Q._CONFIGS
TEMPLATES = Q.TEMPLATES_DIR
RESULTS = CONFIGS / "template_shipped_fidelity.json"
FAMILIES = ("debian", "redhat")
#: Comment leaders of the formats in the catalog: shell/ini/keyvalue (#, ;), C-like (//). XML comments are left as
#: lines — a template that changes one is a template that changed the file.
COMMENT = re.compile(r"^\s*(#|;|//)")
WORK = Path(tempfile.gettempdir()) / "template-fidelity"


# ---------------------------------------------------------------------------------------------------------------
# What is reachable, and where each unit's file lives
# ---------------------------------------------------------------------------------------------------------------

def _load(path: Path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def _meta(name: str) -> dict:
    return _load(TEMPLATES / name / "meta.json", {})


def units() -> list[dict]:
    """Every (template, family, path) a request can name, with the packages that may ship the file."""
    stage = runpy.run_path(str(REPO / "scripts" / "stage-agent-templates.py"), run_name="fidelity")
    bound, referenced = stage["referenced_templates"]()
    reachable = bound | referenced
    index = _load(CONFIGS / "config_template_index.json", {})
    catalog = _load(CONFIGS / "package_catalog.json", {})
    universe = _load(CONFIGS / "package_universe_real.json", {})
    codecs = _load(CONFIGS / "config_codecs.json", {})

    # family templates: (family, path) -> template dir, as nt_engine looks them up
    family_tpl: dict[tuple[str, str], str] = {}
    for name in reachable:
        m = _meta(name)
        if m.get("family") and m.get("target_path"):
            family_tpl[(m["family"], m["target_path"])] = name

    by_path: dict[str, dict[str, list[str]]] = {f: collections.defaultdict(list) for f in FAMILIES}
    for fam in FAMILIES:
        for pkg, entry in (universe.get(fam) or {}).items():
            for p in entry.get("config_paths") or []:
                by_path[fam][p].append(pkg)

    # the codec registry records, per path, the packages it measured the file in (family-neutral)
    codec_pkgs: dict[str, list[str]] = {p: (e.get("packages") or []) for p, e in codecs.items() if isinstance(e, dict)}

    found: dict[tuple[str, str, str], dict] = {}

    def add(template: str, family: str, path: str, how: str, packages: list[str]) -> None:
        if not template or not path or any(ch in path for ch in "*?["):
            return
        template = family_tpl.get((family, path), template)
        key = (template, family, path)
        u = found.setdefault(key, {"template": template, "family": family, "path": path, "via": [], "packages": []})
        if how not in u["via"]:
            u["via"].append(how)
        for p in packages:
            if p and p not in u["packages"]:
                u["packages"].append(p)

    for fam in FAMILIES:
        block = (index.get("families") or {}).get(fam) or index.get("base") or {}
        for path, entry in (block.get("paths") or {}).items():
            add((entry or {}).get("template"), fam, path, "index", [])
    for role, entry in catalog.items():
        name = entry.get("template") if isinstance(entry, dict) else None
        for fam, fe in ((entry or {}).get("families") or {}).items() if isinstance(entry, dict) else ():
            if fam in FAMILIES and isinstance(fe, dict) and name:
                add(name, fam, fe.get("config_path") or "", f"catalog:{role}", fe.get("packages") or [])
    # a family template is reachable through its own key even if neither source names it for that path
    for (fam, path), name in family_tpl.items():
        if (name, fam, path) not in found and fam in FAMILIES:
            add(name, fam, path, "family-template", [])

    out = []
    for u in found.values():
        m = _meta(u["template"])
        stem = u["template"].removesuffix("-redhat")
        cands = [m.get("package") or "", *u["packages"], *by_path[u["family"]].get(u["path"], []),
                 *codec_pkgs.get(u["path"], []), stem, stem.replace("_", "-")]
        u["packages"] = [c for i, c in enumerate(cands) if c and c not in cands[:i]]
        out.append(u)
    # A reachable template no unit names (its path is a pattern, or no family names a file for it) is not dropped:
    # it is listed with verdict no-target, so the count of reachable templates adds up.
    named = {u["template"] for u in out}
    for name in sorted(reachable - named):
        out.append({"template": name, "family": _meta(name).get("family") or "debian", "path": "", "via": [],
                    "packages": [], "no_target": True})
    return sorted(out, key=lambda u: (u["family"], u["template"], u["path"]))


def unit_key(u: dict) -> str:
    return f"{u['family']}|{u['template']}|{u['path']}"


# ---------------------------------------------------------------------------------------------------------------
# Rendering with the agent's engine
# ---------------------------------------------------------------------------------------------------------------

_render_check: Path | None = None


def render_check() -> Path:
    global _render_check
    if _render_check is None:
        WORK.mkdir(parents=True, exist_ok=True)
        out = WORK / "render-check"
        subprocess.run(["go", "build", "-o", str(out), "./cmd/render-check/"], cwd=str(REPO), check=True,
                       capture_output=True, timeout=600)
        _render_check = out
    return _render_check


def render_defaults(name: str) -> tuple[str | None, str]:
    """(rendered text, error) — the template with the values an untouched role sends."""
    return render_dir(TEMPLATES / name)


def render_dir(tdir: Path, overlay: dict | None = None) -> tuple[str | None, str]:
    """Render the template in `tdir` with its schema defaults (nulls left out, dotted keys nested), plus `overlay`."""
    WORK.mkdir(parents=True, exist_ok=True)
    schema = _load(tdir / "schema.json", {})
    values = _nest_dotted(schema_defaults(schema)) if isinstance(schema, dict) else {}
    if overlay:
        values = {**values, **_nest_dotted(overlay)}
    vfile = WORK / f"values-{tdir.name}-{time.monotonic_ns()}.json"
    vfile.write_text(json.dumps(values))
    try:
        r = subprocess.run([str(render_check()), "-template", str(tdir / "template.j2"), "-values", str(vfile)],
                           capture_output=True, text=True, timeout=60)
    finally:
        vfile.unlink(missing_ok=True)
    if r.returncode != 0:
        return None, (r.stderr or r.stdout).strip()[-400:]
    return r.stdout, ""


# ---------------------------------------------------------------------------------------------------------------
# The shipped file
# ---------------------------------------------------------------------------------------------------------------

#: (family, package) -> {"status": "ok"|reason, "files": {path: text}} for the paths asked of that package.
_pkg_cache: dict[tuple[str, str], dict] = {}


def _read_tree(root: Path, want: set[str]) -> dict[str, str]:
    """The wanted paths from an unpacked tree, plus — for a wanted path the tree lacks — the one file elsewhere in
    the tree with the same basename (recorded under "<path>@<where>")."""
    files: dict[str, str] = {}
    all_files = [p for p in root.rglob("*") if p.is_file() and not p.is_symlink()]
    by_base: dict[str, list[Path]] = collections.defaultdict(list)
    for p in all_files:
        by_base[p.name].append(p)
    for path in want:
        f = root / path.lstrip("/")
        if f.is_file():
            files[path] = f.read_text(errors="replace")
            continue
        alts = [p for p in by_base.get(Path(path).name, [])
                if not str(p.relative_to(root)).startswith(("usr/share/man/", "usr/share/doc/"))]
        if len(alts) == 1:
            files[f"{path}@/{alts[0].relative_to(root)}"] = alts[0].read_text(errors="replace")
    return files


def fetch(family: str, pkg: str, want: set[str]) -> dict:
    key = (family, pkg)
    if key in _pkg_cache:
        return _pkg_cache[key]
    res: dict = {"status": "ok", "files": {}}
    if family == "debian":
        if not Q._ensure_debian_apt():
            res["status"] = "debian apt index unavailable"
        else:
            work = Path(tempfile.mkdtemp(dir=str(Q.DEB_TMP)))
            try:
                r = subprocess.run(["apt-get", *Q._apt_opts(), "download", pkg], cwd=str(work),
                                   capture_output=True, text=True, timeout=300)
                debs = list(work.glob("*.deb"))
                if not debs:
                    res["status"] = "apt-get download: " + ((r.stderr or "").strip().splitlines() or ["no .deb"])[-1][:200]
                else:
                    subprocess.run(["dpkg-deb", "-x", str(debs[0]), str(work / "root")], capture_output=True,
                                   timeout=300)
                    res["files"] = _read_tree(work / "root", want)
            except (OSError, subprocess.SubprocessError) as e:
                res["status"] = f"{type(e).__name__}: {e}"[:200]
            finally:
                shutil.rmtree(work, ignore_errors=True)
    else:
        from bossman.tools import rpm_source
        tree = rpm_source.fetch(pkg)
        try:
            if not tree.ok:
                res["status"] = f"rpm: {tree.status}"
            else:
                res["files"] = _read_tree(tree.root, want)
        finally:
            tree.cleanup()
    _pkg_cache[key] = res
    return res


# ---------------------------------------------------------------------------------------------------------------
# Comparing
# ---------------------------------------------------------------------------------------------------------------

def active_lines(text: str) -> list[str]:
    return [" ".join(ln.split()) for ln in text.split("\n") if ln.strip() and not COMMENT.match(ln)]


def compare(rendered: str, shipped: str) -> dict:
    if rendered == shipped:
        return {"verdict": "identical"}
    a, b = collections.Counter(active_lines(rendered)), collections.Counter(active_lines(shipped))
    if a == b:
        return {"verdict": "same-settings"}
    only_r, only_s = list((a - b).elements()), list((b - a).elements())
    return {"verdict": "differs", "only_in_render": only_r[:8], "only_in_shipped": only_s[:8],
            "counts": {"only_in_render": len(only_r), "only_in_shipped": len(only_s),
                       "active_render": sum(a.values()), "active_shipped": sum(b.values())}}


def judge(u: dict, wanted_by_pkg: dict[tuple[str, str], set[str]]) -> dict:
    if u.get("no_target"):
        return {"verdict": "no-target", "reason": "reachable, but no index binding, catalog role or meta.json names a "
                                                  "concrete file for it (a pattern path is not a file)"}
    rendered, err = render_defaults(u["template"])
    if rendered is None:
        return {"verdict": "does-not-render", "error": err}
    reasons, tried = [], []
    for pkg in u["packages"]:
        got = fetch(u["family"], pkg, wanted_by_pkg.get((u["family"], pkg), {u["path"]}) | {u["path"]})
        if got["status"] != "ok":
            reasons.append(f"{pkg}: {got['status']}")
            continue
        tried.append(pkg)
        text = got["files"].get(u["path"])
        where = u["path"]
        if text is None:
            alt = [k for k in got["files"] if k.startswith(u["path"] + "@")]
            if alt:
                where, text = alt[0].split("@", 1)[1], got["files"][alt[0]]
        if text is not None:
            out = {**compare(rendered, text), "package": pkg}
            if where != u["path"]:
                out["shipped_at"] = where
            return out
    if tried:
        return {"verdict": "no-shipped-file", "packages_tried": tried, **({"fetch_failed": reasons} if reasons else {})}
    return {"verdict": "no-package", "fetch_failed": reasons or ["no candidate package"]}


# ---------------------------------------------------------------------------------------------------------------

def summarize(results: dict) -> dict:
    counts: dict[str, collections.Counter] = {f: collections.Counter() for f in FAMILIES}
    for r in results.values():
        counts[r["family"]][r["verdict"]] += 1
    return {f: dict(sorted(c.items())) for f, c in counts.items()}


def save(results: dict) -> None:
    doc = {"what": "stage 5 — each reachable (template, family, path) rendered with its defaults (agent engine) "
                   "vs the file the package ships; see bossman/bossman/tools/template_shipped_fidelity.py",
           "generated": time.strftime("%Y-%m-%dT%H:%M:%S"), "counts": summarize(results),
           "units": dict(sorted(results.items()))}
    tmp = RESULTS.with_suffix(".tmp")
    tmp.write_text(json.dumps(doc, indent=1, ensure_ascii=False) + "\n")
    tmp.replace(RESULTS)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", default="", help="comma-separated template names")
    ap.add_argument("--family", choices=FAMILIES, action="append")
    ap.add_argument("--redo", action="store_true")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--summary", action="store_true", help="print the counts of the results file and exit")
    args = ap.parse_args()
    results = (_load(RESULTS, {}) or {}).get("units", {})
    if args.summary:
        print(json.dumps(summarize(results), indent=1))
        return 0
    todo = units()
    print(f"{len(todo)} unit(s): " + ", ".join(f"{f} {sum(1 for u in todo if u['family'] == f)}" for f in FAMILIES))
    # A unit that is no longer reachable (the index or the catalog stopped naming it) is not a measurement of
    # anything a request can reach: dropped from the results, and the number said.
    current = {unit_key(u) for u in todo}
    stale = [k for k in results if k not in current]
    for k in stale:
        del results[k]
    if stale:
        print(f"{len(stale)} recorded unit(s) are no longer reachable — dropped")
    if args.only:
        only = {s.strip() for s in args.only.split(",")}
        todo = [u for u in todo if u["template"] in only]
    if args.family:
        todo = [u for u in todo if u["family"] in args.family]
    if not args.redo:
        # Not yet measured, or the template changed since its verdict (newer files than the results file's entry).
        def changed(u: dict) -> bool:
            at = (results.get(unit_key(u)) or {}).get("at")
            if not at:
                return True
            tdir = TEMPLATES / u["template"]
            newest = max((f.stat().st_mtime for f in tdir.glob("*.j*") if f.is_file()), default=0)
            return newest > time.mktime(time.strptime(at, "%Y-%m-%dT%H:%M:%S"))
        todo = [u for u in todo if unit_key(u) not in results or changed(u)]
    if args.limit:
        todo = todo[:args.limit]
    # process package by package, so one download serves every unit that names it first
    todo.sort(key=lambda u: (u["family"], u["packages"][:1], u["template"]))
    wanted: dict[tuple[str, str], set[str]] = collections.defaultdict(set)
    for u in todo:
        for p in u["packages"]:
            wanted[(u["family"], p)].add(u["path"])
    WORK.mkdir(parents=True, exist_ok=True)
    for i, u in enumerate(todo, 1):
        t0 = time.monotonic()
        r = judge(u, wanted)
        results[unit_key(u)] = {"template": u["template"], "family": u["family"], "path": u["path"],
                                "via": u["via"], "at": time.strftime("%Y-%m-%dT%H:%M:%S"), **r}
        print(f"[{i}/{len(todo)}] {u['family']}/{u['template']} {u['path']}: {r['verdict']}"
              f"{' (' + r.get('package', '') + ')' if r.get('package') else ''} {time.monotonic() - t0:.1f}s",
              flush=True)
        # bound the per-package cache to what is still to come
        if i % 25 == 0:
            save(results)
            upcoming = {(v["family"], p) for v in todo[i:] for p in v["packages"]}
            for k in [k for k in _pkg_cache if k not in upcoming]:
                del _pkg_cache[k]
    save(results)
    print(json.dumps(summarize(results), indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
