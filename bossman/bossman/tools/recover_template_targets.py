"""Recover WHICH FILE each Debian template renders — by content, from the package itself.

    .venv-host/bin/python -m bossman.tools.recover_template_targets [--only a,b] [--limit N] [--dry-run]

WHY. Measured 2026-10-09: 3440 Debian template directories carry no `target_path`, and the template manifest
withholds 4425 of 5474 templates because nothing binds a path to them. A template that no path names cannot be
opened by the Configuration tab, a policy or the wizard — the package is "configurable" only on paper. That is
the single largest reason a package with a perfectly good template is not configurable today.

WHY BY CONTENT. backfill_template_target.py derived the target from NAMES (codec keys, seed paths), and names
are what failed: a directory is named after the package, the index resolves by file. The pipeline's own rule is
that a template rendered with its OWN defaults reproduces the file the package ships. So the package is
downloaded again (no install), every file it ships under /etc is read, and the template's default render is
compared with each. The file it reproduces is the file it renders. No model, no name heuristics.

THE OUTCOME IS EXHAUSTIVE, one per template, in configs/template_target_recovery.json:
  bound           one shipped file matches clearly (score ≥ MIN_SCORE, ahead of the runner-up by MARGIN)
  ambiguous       two or more files match about equally — recorded with the candidates, nothing chosen
  no-match        the package ships /etc files but none is this template's file
  script-not-config  the file it reproduces is an init/cron/Xsession SCRIPT — never bound, a render would replace code
  no-etc-file     the package ships nothing under /etc (the template has no file to render on Debian)
  does-not-render the template cannot be rendered with its defaults (a different defect, reported, not guessed)
  no-package      no .deb of that name could be downloaded
A template already bound (meta.json with target_path) is never touched.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

from bossman.tools import qualify_packages as Q  # noqa: E402
from bossman.tools.template_invariants import render_with_defaults  # noqa: E402

TEMPLATES = Q.TEMPLATES_DIR
RESULTS = Q._CONFIGS / "template_target_recovery.json"
#: Jaccard similarity of the non-blank line sets. 0.6 accepts a template whose defaults differ from the shipped
#: values on a few lines (the alignment pass did not reach every default); below it the "match" is usually a
#: sibling file of the same package that shares a comment header.
MIN_SCORE = 0.6
MARGIN = 0.15
#: A file the template reproduces but that is a SCRIPT, not configuration: run-parts and init execute these, and a
#: whole-file render would replace working code with rendered text. Same refusal as the template index's.
SCRIPT_DIR = re.compile(r"^/etc/(init\.d|rc\d?\.d|cron\.(hourly|daily|weekly|monthly)|X11/Xsession\.d)/")


def _lines(text: str) -> set[str]:
    return {ln.strip() for ln in text.split("\n") if ln.strip()}


def score(rendered: str, shipped: str) -> float:
    a, b = _lines(rendered), _lines(shipped)
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def candidate_packages(name: str, catalog_pkgs: dict[str, list[str]], by_basename: dict[str, list[str]]) -> list[str]:
    """Packages that may ship this template's file: the catalog's, the name itself (and its hyphen form), the
    packages the codec registry records for a file of that basename (`LCDd.conf` is lcdproc's), and the stem
    of a seed key (`a2jmidid_daemon` → a2jmidid)."""
    out: list[str] = []
    stem = name.split("_", 1)[0]
    for c in (*catalog_pkgs.get(name, []), name, name.replace("_", "-"), *by_basename.get(name, []), stem):
        if c and c not in out:
            out.append(c)
    return out


def etc_files(pkg: str) -> dict[str, str] | None:
    """Every regular file the .deb ships under /etc, path -> text. None when the package cannot be fetched."""
    if not Q._ensure_debian_apt():
        return None
    work = Path(tempfile.mkdtemp(dir=str(Q.DEB_TMP)))
    try:
        subprocess.run(["apt-get", *Q._apt_opts(), "download", pkg], cwd=str(work),
                       capture_output=True, timeout=180)
        debs = list(work.glob("*.deb"))
        if not debs:
            return None
        root = work / "root"
        subprocess.run(["dpkg-deb", "-x", str(debs[0]), str(root)], capture_output=True, timeout=120)
        out: dict[str, str] = {}
        etc = root / "etc"
        for f in sorted(etc.rglob("*")) if etc.is_dir() else []:
            if f.is_file() and not f.is_symlink():
                try:
                    out["/" + str(f.relative_to(root))] = f.read_text(errors="replace")[:200000]
                except OSError:
                    continue
        return out
    except (OSError, subprocess.SubprocessError):
        return None
    finally:
        shutil.rmtree(work, ignore_errors=True)


def recover(name: str, catalog_pkgs: dict[str, list[str]], by_basename: dict[str, list[str]]) -> dict:
    rendered = render_with_defaults(TEMPLATES / name)
    if rendered is None:
        return {"outcome": "does-not-render"}
    fetched_any = False
    best: list[tuple[float, str, str]] = []
    for pkg in candidate_packages(name, catalog_pkgs, by_basename):
        files = etc_files(pkg)
        if files is None:
            continue
        fetched_any = True
        for path, text in files.items():
            best.append((score(rendered, text), path, pkg))
        if best and max(best)[0] >= MIN_SCORE:
            break   # this package carries the file; its siblings need not be downloaded
    if not fetched_any:
        return {"outcome": "no-package"}
    if not best:
        return {"outcome": "no-etc-file"}
    best.sort(reverse=True)
    top = best[0]
    runner = best[1][0] if len(best) > 1 else 0.0
    cands = [{"path": p, "package": k, "score": round(s, 3)} for s, p, k in best[:4]]
    if top[0] < MIN_SCORE:
        return {"outcome": "no-match", "candidates": cands}
    if top[0] - runner < MARGIN:
        return {"outcome": "ambiguous", "candidates": cands}
    if SCRIPT_DIR.match(top[1]):
        return {"outcome": "script-not-config", "path": top[1], "package": top[2], "score": round(top[0], 3)}
    return {"outcome": "bound", "path": top[1], "package": top[2], "score": round(top[0], 3),
            "runner_up": round(runner, 3)}


def write_meta(name: str, res: dict) -> None:
    meta_p = TEMPLATES / name / "meta.json"
    prev = {}
    if meta_p.is_file():
        try:
            prev = json.loads(meta_p.read_text())
        except ValueError:
            prev = {}
    meta = {"target_path": res["path"], "source": "recover_template_targets", "witness": "deb-content",
            "package": res["package"], "match": res["score"]}
    if prev:
        # The earlier name-based record (ambiguous_with / candidate_path) is kept, not erased: it is the
        # evidence of why this template was unreachable before.
        meta["previous"] = prev
    meta_p.write_text(json.dumps(meta, indent=2) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", default="")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--dry-run", action="store_true", help="measure and report, write no meta.json")
    ap.add_argument("--redo", action="store_true", help="re-measure templates already in the results file")
    args = ap.parse_args()

    catalog = Q._load(Q.CATALOG, {})
    catalog_pkgs: dict[str, list[str]] = {}
    for info in catalog.values():
        t = info.get("template") if isinstance(info, dict) else None
        if t:
            catalog_pkgs.setdefault(t, []).extend(
                ((info.get("families") or {}).get("debian") or {}).get("packages") or [])

    by_basename: dict[str, list[str]] = {}
    for path, entry in Q._load(Q.CODECS, {}).items():
        pk = entry.get("packages") if isinstance(entry, dict) else None
        if pk:
            by_basename.setdefault(path.rsplit("/", 1)[-1], []).extend(p for p in pk if isinstance(p, str))

    results = Q._load(RESULTS, {})
    only = {s.strip() for s in args.only.split(",") if s.strip()}
    todo = []
    for d in sorted(TEMPLATES.iterdir()):
        if not d.is_dir() or d.name.endswith(Q.REDHAT_SUFFIX) or d.name in Q._CURATED:
            continue
        if only and d.name not in only:
            continue
        meta = Q._load(d / "meta.json", {})
        if isinstance(meta, dict) and meta.get("target_path"):
            continue
        if d.name in results and not args.redo and not only:
            continue
        todo.append(d.name)
    if args.limit:
        todo = todo[: args.limit]
    print(f"recover_template_targets: {len(todo)} unbound template(s) to measure", flush=True)

    for i, name in enumerate(todo, 1):
        res = recover(name, catalog_pkgs, by_basename)
        if res["outcome"] == "bound" and not args.dry_run:
            write_meta(name, res)
        results[name] = res
        extra = f" → {res.get('path')} ({res.get('score')})" if res["outcome"] == "bound" else ""
        print(f"[{i}/{len(todo)}] {name}: {res['outcome']}{extra}", flush=True)
        if i % 20 == 0 and not args.dry_run:
            Q._write_json(RESULTS, results, sort=True)
    if not args.dry_run:
        Q._write_json(RESULTS, results, sort=True)
    counts: dict[str, int] = {}
    for r in results.values():
        counts[r["outcome"]] = counts.get(r["outcome"], 0) + 1
    print("outcomes:", json.dumps(counts, sort_keys=True), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
