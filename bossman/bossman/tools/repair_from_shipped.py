"""Run the mechanical repair chain on every template stage 5 found to change its file — and keep only what helps.

    .venv-host/bin/python -m bossman.tools.repair_from_shipped [--catalog] [--family debian|redhat]
                                                               [--only a,b] [--limit N] [--write]

WHY. template_repair_chain.repair_template holds the six deterministic repairs (restore lines the model mangled,
put back comments where the model switched a setting on, take the defaults from the shipped file, …) — and nothing
called it. Stage 5 (template_shipped_fidelity) then measured what that costs: with its own defaults, about half the
Debian catalog roles' templates do not reproduce the file the package ships, so applying the role untouched changes
the host.

WHAT IT DOES, per template whose unit says `differs`: fetch the shipped file (the package and path stage 5
recorded), copy the template to a scratch directory, run the chain there, render it again with its defaults and
compare. The repair is KEPT only when
  - the verdict improves (differs → same-settings/identical), or it stays `differs` with strictly fewer differing
    active lines, and
  - the sample still renders (a repair that breaks the operator's values is no repair).
Otherwise the template is left as it was and the reason recorded. Without --write nothing is changed.

Every decision goes to configs/template_shipped_repairs.json: template, family, before/after verdict and counts,
what each chain step changed, kept or not and why. The fidelity results are updated for the units that were
re-rendered.
"""

from __future__ import annotations

import argparse
import json
import shutil
import tempfile
import time
from pathlib import Path

from bossman.tools import template_shipped_fidelity as F
from bossman.tools.template_repair_chain import repair_template

REPAIRS = F.CONFIGS / "template_shipped_repairs.json"
RANK = {"identical": 0, "same-settings": 1, "differs": 2}


def _diff_total(r: dict) -> int:
    c = r.get("counts") or {}
    return int(c.get("only_in_render", 0)) + int(c.get("only_in_shipped", 0))


def better(before: dict, after: dict) -> bool:
    if after.get("verdict") not in RANK:
        return False
    if RANK[after["verdict"]] != RANK[before["verdict"]]:
        return RANK[after["verdict"]] < RANK[before["verdict"]]
    return after["verdict"] == "differs" and _diff_total(after) < _diff_total(before)


def shipped_text(unit: dict) -> str | None:
    path = unit.get("shipped_at") or unit["path"]
    got = F.fetch(unit["family"], unit["package"], {path})
    if got["status"] != "ok":
        return None
    return got["files"].get(path)


def _verdict_rank(r: dict) -> tuple[int, int]:
    return (RANK.get(r.get("verdict"), 3), _diff_total(r))


def repair_one(unit: dict, write: bool, siblings: list[dict] | None = None) -> dict:
    name = unit["template"]
    src = F.TEMPLATES / name
    out: dict = {"template": name, "family": unit["family"], "path": unit["path"], "package": unit.get("package"),
                 "before": {"verdict": unit["verdict"], "counts": unit.get("counts")},
                 "at": time.strftime("%Y-%m-%dT%H:%M:%S")}
    shipped = shipped_text(unit)
    if shipped is None:
        return {**out, "kept": False, "why": "the shipped file could not be fetched again"}
    sample = F._load(src / "sample.json", {})
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp) / name
        shutil.copytree(src, work)
        out["steps"] = repair_template(work, shipped, write=True)
        rendered, err = F.render_dir(work)
        if rendered is None:
            return {**out, "kept": False, "why": f"after the chain the template does not render: {err[-200:]}"}
        after = F.compare(rendered, shipped)
        out["after"] = {"verdict": after["verdict"], "counts": after.get("counts")}
        if not better(unit, after):
            return {**out, "kept": False, "why": "the chain did not reduce the difference to the shipped file"}
        # ONE TEMPLATE, SEVERAL FILES: a template bound on both families was repaired against the EL file and got
        # worse for Debian (measured: 17 units, e.g. c-icap, mosquitto, munin). Every other unit of the template must
        # not get worse, or the repair is not kept.
        for sib in siblings or []:
            sib_text = shipped_text(sib) if sib.get("package") else None
            if sib_text is None or sib.get("verdict") not in RANK:
                continue
            sib_after = F.compare(rendered, sib_text)
            if _verdict_rank(sib_after) > _verdict_rank(sib):
                return {**out, "kept": False,
                        "why": f"it would make the {sib['family']} unit ({sib['path']}) worse: "
                               f"{sib['verdict']} -> {sib_after['verdict']}"}
        if isinstance(sample, dict) and sample:
            ok, err = F.render_dir(work, sample)
            if ok is None:
                return {**out, "kept": False, "why": f"after the chain the SAMPLE does not render: {err[-200:]}"}
        out["kept"] = True
        if write:
            for f in ("template.j2", "schema.json"):
                if (work / f).is_file():
                    shutil.copy2(work / f, src / f)
            # Marked, so the qualify batch does not regenerate a verified repair (qualify_packages._curated).
            meta = F._load(src / "meta.json", {})
            meta["repaired"] = f"{time.strftime('%Y-%m-%d')} template_repair_chain against the shipped file"
            (src / "meta.json").write_text(json.dumps(meta, indent=2) + "\n")
        out["fidelity"] = {**after, "package": unit.get("package"),
                           **({"shipped_at": unit["shipped_at"]} if unit.get("shipped_at") else {})}
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--catalog", action="store_true", help="only units a catalog role reaches")
    ap.add_argument("--family", choices=F.FAMILIES, action="append")
    ap.add_argument("--only", default="")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()
    doc = F._load(F.RESULTS, {})
    units = doc.get("units", {})
    todo = [dict(v, _key=k) for k, v in units.items() if v.get("verdict") == "differs" and v.get("package")]
    is_catalog = lambda u: any(x.startswith("catalog:") for x in u.get("via", []))   # noqa: E731
    if args.catalog:
        todo = [u for u in todo if is_catalog(u)]
    else:
        # A catalog role's template is repaired only with --catalog, whose result must then be run for real: the
        # general pass once rewrote containerd's config.toml again after its runtime revert (measured 2026-10-11).
        todo = [u for u in todo if not is_catalog(u)]
    if args.family:
        todo = [u for u in todo if u["family"] in args.family]
    if args.only:
        only = {s.strip() for s in args.only.split(",")}
        todo = [u for u in todo if u["template"] in only]
    # one repair per template: a template reached by several units is repaired against its first unit's file
    seen: set[str] = set()
    todo = [u for u in sorted(todo, key=lambda u: (u["family"], u["template"]))
            if not (u["template"] in seen or seen.add(u["template"]))]
    if args.limit:
        todo = todo[:args.limit]
    log = F._load(REPAIRS, {})
    # A repair the runtime refused (the daemon failed on the repaired file) is never tried again.
    vetoed = {v["template"] for v in log.values() if v.get("reverted")}
    todo = [u for u in todo if u["template"] not in vetoed]
    kept = 0
    by_template: dict[str, list[dict]] = {}
    for k, v in units.items():
        by_template.setdefault(v["template"], []).append(dict(v, _key=k))
    for i, u in enumerate(todo, 1):
        siblings = [s for s in by_template.get(u["template"], []) if s["_key"] != u["_key"]]
        r = repair_one(u, args.write, siblings)
        log[f"{u['family']}|{u['template']}"] = r
        kept += bool(r.get("kept"))
        a = r.get("after") or {}
        print(f"[{i}/{len(todo)}] {u['family']}/{u['template']}: {'KEPT' if r.get('kept') else 'left'} "
              f"{u['verdict']}({_diff_total(u)}) -> {a.get('verdict', '-')}({_diff_total(a) if a else '-'})"
              f"{'' if r.get('kept') else ' — ' + r.get('why', '')}", flush=True)
        if args.write and r.get("kept"):
            units[u["_key"]] = {**{k: v for k, v in u.items() if k != "_key"}, **r["fidelity"], "at": r["at"]}
            for k in ("only_in_render", "only_in_shipped", "counts"):
                if k not in r["fidelity"]:
                    units[u["_key"]].pop(k, None)
    REPAIRS.write_text(json.dumps(dict(sorted(log.items())), indent=1, ensure_ascii=False) + "\n")
    if args.write:
        F.save(units)
    print(f"{kept} of {len(todo)} repaired{'' if args.write else ' (dry run — nothing written)'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
