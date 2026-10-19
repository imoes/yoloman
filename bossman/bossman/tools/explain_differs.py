"""Why each reachable template that still changes its file with its defaults was NOT fixed mechanically.

    .venv-host/bin/python -m bossman.tools.explain_differs [--family debian|redhat] [--only a,b]

Plan item E2 is done when no reachable template differs without a recorded reason. A `differs` verdict alone says
WHAT; this records WHY it is still so, one entry per (family, template, path) in configs/template_differs_reasons.json:

  wrong-file         the template renders ANOTHER file: not one setting name it writes occurs in the shipped file,
                     active or commented (ssh_config written into /etc/default/ssh, a namesake template on a
                     logcheck fragment, a target /etc/<package> invented next to a binary). No repair can fix a
                     binding; the template index withdraws it (template_index, verdict `wrong-file`)
  repair-vetoed      the repair broke the daemon when run for real (the runtime veto in the repairs log)
  repair-refused     the chain's result was not kept — the reason it gives (no gain, a sibling unit worse, the
                     sample stopped rendering)
  rebuild-loses      rebuilding from the shipped file with the template's own field names would drop these fields
                     (the operator would lose knobs; a per-role decision, not a mechanical one)
  rebuild-unfaithful the rebuild does not reproduce the file either (it did not render, or still differs)
  unfieldable        the shipped file has no `key value` lines the builder can field (XML, JSON, blocks, scripts)
  shared-template    a lossless rebuild for this file exists, but the template also renders another family's file
  shipped-unavailable the shipped file could not be fetched again
A unit gets every reason that applies; its `category` is the first in the order wrong-file, vetoed, rebuild-loses,
unfieldable, rebuild-unfaithful, repair-refused, shipped-unavailable — the one that decides why it is not fixed.
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import re
import tempfile
import time
from pathlib import Path

from bossman.tools import template_shipped_fidelity as F
from bossman.tools.repair_from_shipped import shipped_text
from bossman.tools.template_from_shipped import build, role_names

OUT = F.CONFIGS / "template_differs_reasons.json"
ORDER = ("wrong-file", "repair-vetoed", "rebuild-loses", "unfieldable", "rebuild-unfaithful", "shared-template", "repair-refused",
         "shipped-unavailable")


_KEY = re.compile(r'^\s*(?:export\s+)?([A-Za-z_@*:<\[{"/.-][^\s=:]*)')


def setting_names(text: str, commented: bool = False) -> set[str]:
    """The first token of each setting line — `key` of `key = v`, `Key v`, `KEY=v`, `<Section`, `[section]`.

    With `commented`, commented lines count too: a shipped file that documents its settings as comments
    (`#Port 22`) still names them, and a template that activates one of those is configuring THIS file.
    """
    out: set[str] = set()
    for line in text.splitlines():
        s = line.strip()
        if not s:
            continue
        if s.startswith(("#", ";", "//", "--")):    # `--`: Lua and SQL (diod.conf, kresd.conf)
            if not commented:
                continue
            s = s.lstrip("#;/- ").strip()
        m = _KEY.match(s)
        if m:
            out.add(m.group(1).strip('"[]{}<>').lower())
    return out - {""}


def wrong_file(rendered: str, shipped: str) -> dict | None:
    """The template writes settings of which NONE occurs in the shipped file — it renders another file.

    Measured 2026-10-14 over 1209 differing units: 375 share no setting name with their file (ssh_config in
    /etc/default/ssh, JSON in /etc/default/docker, the `mdadm` template on a logcheck fragment, `config.ini`
    of one application bound to every config.ini). Partial overlap is NOT this: a template with half the
    file's settings is a differing template of the right file.
    """
    mine = setting_names(rendered)
    # Judged only against a file that HAS settings: a shipped file of comments alone (EL's dhcpd.conf is "see
    # dhcpd.conf(5)") is filled by a correct template with settings it cannot name — measured, 9 catalog roles that
    # are compliant would have been withdrawn. A binary is no config file to compare with either.
    if not mine or "\x00" in shipped or not setting_names(shipped):
        return None
    theirs = setting_names(shipped, commented=True)
    if mine & theirs:
        return None
    return {"writes": sorted(mine)[:6], "file_has": sorted(theirs)[:6],
            "reason": "none of the settings this template writes occurs in the shipped file (active or commented) "
                      "— it renders another file"}


def template_sha(name: str) -> str | None:
    try:
        return hashlib.sha256((F.TEMPLATES / name / "template.j2").read_bytes()).hexdigest()[:16]
    except OSError:
        return None


def keep(key: str, entry: dict, units: dict) -> bool:
    """Is a recorded reason still about something real?

    A `differs` unit: while it still differs. A `wrong-file` unit ALSO after it left the results: the template index
    withdraws that binding, so stage 5 no longer reaches it and drops it — and if the reason went with it, the next
    index build would bind the template to the same file again (an oscillation). It stays until the template itself
    changes (its hash), which is the one event that can make the measurement wrong.
    """
    if key in units and units[key].get("verdict") == "differs":
        return True
    return entry.get("category") == "wrong-file" and entry.get("template_sha") == template_sha(entry.get("template"))


def explain(unit: dict, repairs: dict, all_units: list[dict] = ()) -> dict:
    reasons: dict[str, object] = {}
    log = repairs.get(f"{unit['family']}|{unit['template']}") or {}
    if log.get("reverted"):
        reasons["repair-vetoed"] = log["reverted"]
    elif log.get("kept") is False and log.get("why"):
        reasons["repair-refused"] = log["why"]
    text = shipped_text(unit) if unit.get("package") else None
    if text is None:
        reasons["shipped-unavailable"] = "the package's file could not be fetched again"
    else:
        tdir = F.TEMPLATES / unit["template"]
        own, _err = F.render_dir(tdir)
        # Only the file AT the path: where stage 5 fell back to another file of the package (`shipped_at`: the
        # binary, the init script, a tmpfiles.d entry), the comparison says nothing about this binding.
        at_path = (unit.get("shipped_at") or unit["path"]) == unit["path"]
        wf = wrong_file(own, text) if own is not None and at_path else None
        if wf:
            reasons["wrong-file"] = wf
        schema = F._load(tdir / "schema.json", {})
        names = {k: v for k, v in role_names((tdir / "template.j2").read_text(errors="replace")).items()
                 if v in schema}
        body, new_schema = build(text, names=names, role_schema=schema)
        if not new_schema:
            reasons["unfieldable"] = "the shipped file has no directive line the builder can turn into a field"
        else:
            with tempfile.TemporaryDirectory() as d:
                w = Path(d) / unit["template"]
                w.mkdir()
                (w / "template.j2").write_text(body)
                (w / "schema.json").write_text(json.dumps(new_schema))
                out, err = F.render_dir(w)
            verdict = F.compare(out, text)["verdict"] if out is not None else "does-not-render"
            lost = sorted(set(schema) - set(new_schema))
            if verdict not in ("identical", "same-settings"):
                reasons["rebuild-unfaithful"] = verdict
            elif lost:
                reasons["rebuild-loses"] = lost
            else:
                # Faithful and lossless for THIS file — but the template also renders another family's file, and a
                # rebuild against one makes the other worse (the sibling rule). Fixed by its own family template.
                siblings = [s for s in all_units if s["template"] == unit["template"] and s is not unit]
                if siblings:
                    reasons["shared-template"] = (f"also renders the {siblings[0]['family']} file "
                                                  f"({siblings[0]['path']}); needs its own family template")
    category = next((k for k in ORDER if k in reasons), "unexplained")
    return {"template": unit["template"], "template_sha": template_sha(unit["template"]),
            "family": unit["family"], "path": unit["path"],
            "catalog": any(x.startswith("catalog:") for x in unit.get("via", [])),
            "category": category, "reasons": reasons}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--family", choices=F.FAMILIES, action="append")
    ap.add_argument("--only", default="")
    args = ap.parse_args()
    units = F._load(F.RESULTS, {}).get("units", {})
    repairs = F._load(F.CONFIGS / "template_shipped_repairs.json", {})
    todo = {k: v for k, v in units.items() if v.get("verdict") == "differs"}
    if args.family:
        todo = {k: v for k, v in todo.items() if v["family"] in args.family}
    if args.only:
        only = {s.strip() for s in args.only.split(",")}
        todo = {k: v for k, v in todo.items() if v["template"] in only}
    doc = F._load(OUT, {}).get("units", {})
    doc = {k: v for k, v in doc.items() if keep(k, v, units)}  # drop fixed ones
    for i, (k, u) in enumerate(sorted(todo.items()), 1):
        doc[k] = explain(u, repairs, list(units.values()))
        if i % 50 == 0:
            print(f"[{i}/{len(todo)}]", flush=True)
    counts: dict = {}
    for scope in ("catalog", "all"):
        c = collections.Counter((v["family"], v["category"]) for v in doc.values() if scope == "all" or v["catalog"])
        counts[scope] = {f: dict(sorted((cat, n) for (fam, cat), n in c.items() if fam == f)) for f in F.FAMILIES}
    OUT.write_text(json.dumps({"what": "why each reachable `differs` unit was not fixed mechanically — "
                                       "bossman/bossman/tools/explain_differs.py",
                               "generated": time.strftime("%Y-%m-%dT%H:%M:%S"), "counts": counts,
                               "units": dict(sorted(doc.items()))}, indent=1, ensure_ascii=False) + "\n")
    print(json.dumps(counts, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
