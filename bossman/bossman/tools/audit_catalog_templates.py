"""Does every catalog role's template describe the file its package ships? Measured, per family, no model involved.

    .venv-host/bin/python -m bossman.tools.audit_catalog_templates [--family debian|redhat] [--only a,b]

For each role with a template and a config path, download the family's package (no install), read the shipped file,
and run the semantic template invariants (tools/template_invariants.ok_semantic) against it. Writes
configs/catalog_template_audit.json — per (family, role): the verdict and what failed — and prints the
`qualify_packages --repair TEMPLATE=PACKAGE` list for the templates that do not describe their file.

WHY A SWEEP. The Bossman-path baseline found 37 roles whose daemon runs with the shipped config and not after the
wizard; ten sampled all failed the invariants for the same reason — older templates written from man pages before
the pipeline parametrized the shipped file (conntrackd: 17 invented lines; e2guardian: an `[main]` INI section in a
file that has none). Patching them one by one would be whack-a-mole; measuring all of them says which to regenerate.

The template examined is the one the wizard renders for that family (the engine's choice: a template recorded for
THIS family's file, else the catalog's).
"""

from __future__ import annotations

import argparse

from bossman.tools import qualify_packages as Q
from bossman.tools.package_tree import unpacked
from bossman.tools.template_invariants import mechanical

OUT = Q._CONFIGS / "catalog_template_audit.json"


def family_template(entry: dict, family: str, path: str) -> str | None:
    for d in Q.TEMPLATES_DIR.iterdir():
        meta = Q._load(d / "meta.json", {}) if d.is_dir() else {}
        if isinstance(meta, dict) and meta.get("family") == family and meta.get("target_path") == path and family != "debian":
            return d.name
    return entry.get("template")


def repair_candidates() -> dict[str, list[str]]:
    """TEMPLATE=PACKAGE pairs worth regenerating: the template fails FUNCTIONALLY (the Bossman-path baseline says
    `template` — the daemon runs with the shipped file, not after the role — or the package's checker rejected it in
    the pod) AND does not describe its shipped file AND is not hand-written (no wizard playbook, not curated).
    Hand-written templates are structured on purpose and pass their checkers; regenerating them destroys work."""
    import json as _json
    audit = Q._load(OUT, {})
    failing: set[tuple[str, str]] = set()
    base = Q._CONFIGS / "package_e2e_bossman_baseline.jsonl"
    for line in base.read_text().splitlines() if base.is_file() else []:
        row = _json.loads(line)
        if row.get("verdict") == "template":
            failing.add((row["family"], row["role"]))
    res = Q._CONFIGS / "package_e2e_results.jsonl"
    latest: dict = {}
    for line in res.read_text().splitlines() if res.is_file() else []:
        row = _json.loads(line)
        latest[(row.get("family"), row.get("package"))] = row
    catalog = Q._load(Q.CATALOG, {})
    by_pkg = {(f, p): r for r, e in catalog.items() for f, b in (e.get("families") or {}).items()
              if isinstance(b, dict) for p in b.get("packages") or []}
    for (fam, pkg), row in latest.items():
        if row.get("outcome") in ("validate-failed", "daemon-failed", "render-failed") and (fam, pkg) in by_pkg:
            failing.add((fam, by_pkg[(fam, pkg)]))
    pbdir = Q._CONFIGS / "wizard_playbooks"
    out: dict[str, list[str]] = {}
    for fam, role in sorted(failing):
        a = audit.get(f"{fam}:{role}") or {}
        if a.get("verdict") != "does-not-describe-the-file" or not a.get("package"):
            continue
        if (pbdir / f"install-{role}.yml").is_file() or a["template"] in Q._CURATED:
            continue
        out.setdefault(fam, []).append(f"{a['template']}={a['package']}")
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--family", choices=("debian", "redhat"), action="append")
    ap.add_argument("--only", default="")
    ap.add_argument("--from-failures", action="store_true",
                    help="print the --repair pairs for templates that fail functionally AND do not describe their file")
    args = ap.parse_args()
    if args.from_failures:
        for family, pairs in repair_candidates().items():
            print(f"--family {family} --repair " + ",".join(pairs))
        return 0
    catalog = Q._load(Q.CATALOG, {})
    only = {s.strip() for s in args.only.split(",") if s.strip()}
    out = Q._load(OUT, {})
    repair: dict[str, list[str]] = {}
    for family in args.family or ["debian", "redhat"]:
        for role, entry in sorted(catalog.items()):
            branch = ((entry.get("families") or {}).get(family) or {}) if isinstance(entry, dict) else {}
            path = branch.get("config_path") or ""
            if not entry.get("template") or not path or branch.get("unavailable") or (only and role not in only):
                continue
            tname = family_template(entry, family, path)
            pkgs = branch.get("packages") or [role]
            shipped, owner = None, None
            for pkg in pkgs:
                with unpacked(family, pkg) as root:
                    f = root / path.lstrip("/") if root else None
                    if f and f.is_file():
                        shipped, owner = f.read_text(errors="replace")[:200000], pkg
                        break
            key = f"{family}:{role}"
            if shipped is None:
                out[key] = {"template": tname, "path": path, "verdict": "not-shipped",
                            "reason": "no package of the role ships the file — the configuration creates it"}
            else:
                m = mechanical(Q.TEMPLATES_DIR / tname, shipped)
                out[key] = {"template": tname, "path": path, "package": owner,
                            "verdict": "describes-the-file" if m["ok_semantic"] else "does-not-describe-the-file",
                            "renders": m["renders"], "keeps_the_settings": m["keeps_the_settings"],
                            "undeclared": m["undeclared"][:8], "invented_active_lines": m["invented_active_lines"],
                            "default_render_diff_active": m["default_render_diff_active"][:5]}
                if not m["ok_semantic"]:
                    repair.setdefault(family, []).append(f"{tname}={owner}")
            print(f"{key}: {out[key]['verdict']}", flush=True)
            Q._write_json(OUT, out, sort=True)
    for family, pairs in repair.items():
        print(f"\n--family {family} --repair " + ",".join(pairs))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
