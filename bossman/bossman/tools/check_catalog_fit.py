"""Do the three catalogs fit? One check, so the question stops being a series of hand measurements.

    python -m bossman.tools.check_catalog_fit          # report; exit 1 if an invariant is violated
    python -m bossman.tools.check_catalog_fit --baseline  # rewrite the tolerated counts

Templates, enums and directives are written by five passes and a nightly LLM batch. Every rule below was
learned from a defect that reached the editor, and each is cheap to check and expensive to rediscover — so
they are checked together, after any batch pass, rather than remembered.

TWO KINDS OF FINDING, deliberately separated:

  INVARIANT   must be zero. A violation means a pass is wrong or a new one broke a rule.
  BUDGET      cannot be zero yet, and must not GROW. The number is recorded in
              configs/catalog_fit_baseline.json with what it is; a rise fails the check and a fall updates
              the file, so progress ratchets and regression is loud.

The budgets are the honest half. "115 templates render a Python-cased boolean" is not something to assert
away; it is something to drive down, and a check that only reported zero-or-not would have had nothing to say
about it for the two days it took to go from 214 to 9.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

from bossman.tools._jsonio import write_catalog
from bossman.tools._paths import configs_dir

CONFIGS = configs_dir(__file__)
TEMPLATES = CONFIGS / "config_templates"
BASELINE = CONFIGS / "catalog_fit_baseline.json"

#: Type words a catalog may store. A new one appearing is a finding, not a silent pass-through: the renderer
#: knows a fixed set, and `boolean`/`integer` cost 427 checkbox fields their control until they were mapped.
KNOWN_TYPES = {"string", "int", "number", "bool", "list", "object", "enum", "path", "secret", "float",
               "boolean", "integer", "array", "flat_map", "bool|string", "string|bool"}
#: …of which these are the ones the serving layer has to translate. Kept explicit so the two lists cannot
#: drift apart silently.
TRANSLATED_TYPES = {"boolean", "integer", "array", "flat_map", "bool|string", "string|bool", "number", "float"}


def _values(spec: dict):
    for key in ("values", "enum"):
        got = spec.get(key)
        if isinstance(got, list):
            return key, got
    return None, None


def _walk_templates():
    for d in sorted(p for p in TEMPLATES.iterdir() if p.is_dir()):
        try:
            schema = json.loads((d / "schema.json").read_text())
        except (OSError, ValueError):
            continue
        props = schema.get("properties", schema) if isinstance(schema, dict) else {}
        if isinstance(props, dict):
            yield d.name, props


def check() -> tuple[dict[str, list[str]], dict[str, int]]:
    """(violations by invariant name, budget counts)."""
    bad: dict[str, list[str]] = {}
    budget: dict[str, int] = {}

    def fail(rule: str, detail: str) -> None:
        bad.setdefault(rule, []).append(detail)

    directives = json.loads((CONFIGS / "config_directives.json").read_text())
    index = json.loads((CONFIGS / "config_template_index.json").read_text())
    paths = (index.get("base") or {}).get("paths") or {}

    # ---- invariants over both catalogs -------------------------------------------------------------
    for where, container, shape in (
        *[(f"template:{n}", p, "template") for n, p in _walk_templates()],
        *[(f"directive:{path}", spec, "directive")
          for path, spec in directives.items() if isinstance(spec, dict)],
    ):
        for key, spec in container.items():
            if not isinstance(spec, dict):
                continue
            set_key, values = _values(spec)
            if values is not None:
                if len(values) < 2:
                    fail("a value set with fewer than two options", f"{where}::{key} = {values}")
                seen = [str(v) for v in values]
                if len(set(seen)) != len(seen):
                    fail("a value set with a duplicate", f"{where}::{key} = {values}")
                labels = spec.get("value_labels") or spec.get("enum_labels")
                if isinstance(labels, dict):
                    orphans = sorted(set(labels) - set(seen))
                    if orphans:
                        fail("a label for a value that is gone", f"{where}::{key} -> {orphans}")
            elif spec.get("enum_open"):
                fail("marked as an open set but has no values", f"{where}::{key}")
            if isinstance(spec.get("default"), bool) and spec.get("type") in ("string", None):
                fail("a JSON boolean default on a text field", f"{where}::{key}")
            typ = spec.get("type")
            if isinstance(typ, str) and typ and typ not in KNOWN_TYPES:
                fail("an unknown type word", f"{where}::{key} = {typ!r}")
            if isinstance(typ, (dict, list)):
                fail("a type that is not a word", f"{where}::{key}")

    # ---- invariants ACROSS the two, for a path bound to a template ---------------------------------
    disagreements = 0
    one_sided = 0
    schemas = {name: props for name, props in _walk_templates()}
    for path, spec in directives.items():
        tname = (paths.get(path) or {}).get("template")
        if not tname or not isinstance(spec, dict):
            continue
        props = schemas.get(tname)
        if props is None:
            continue
        for key, dspec in spec.items():
            tspec = props.get(key)
            if not isinstance(dspec, dict) or not isinstance(tspec, dict):
                continue
            _dk, dvals = _values(dspec)
            _tk, tvals = _values(tspec)
            if dvals and tvals and {str(v) for v in dvals} != {str(v) for v in tvals}:
                disagreements += 1
            elif bool(dvals) != bool(tvals):
                one_sided += 1
            if bool(dspec.get("enum_open")) != bool(tspec.get("enum_open")) and dvals and tvals:
                fail("open on one side and closed on the other",
                     f"{path}::{key} — the same set cannot be both suggestions and the whole range")
    budget["value sets that disagree between the catalogs"] = disagreements
    budget["settings with a value set on only one side"] = one_sided

    # A template body that writes a bare Python-cased boolean as a value. NOT rendered here — that needs the
    # Go engine (cmd/fix-bool-render) — so this counts the STATIC shape: a `{{ x }}` whose schema default is a
    # bool, with nothing piped. An approximation on purpose: the exact number needs a render, and a check
    # that needs a Go build to run would not run.
    #
    # AND IT CANNOT GO TO ZERO, because for a Python-ecosystem config `True` is the CORRECT literal:
    # glances, mopidy, carbon, ceph-mgr and every OpenStack .conf are read by Python's configparser. 13
    # templates hardcode True/False in their bodies and all 13 are that case. The budget exists to notice a
    # RISE — a new template written the wrong way — not to reach zero.
    unpiped = 0
    for name, props in _walk_templates():
        try:
            body = (TEMPLATES / name / "template.j2").read_text()
        except OSError:
            continue
        for key, spec in props.items():
            if not isinstance(spec, dict) or not isinstance(spec.get("default"), bool):
                continue
            base = re.escape(key.split(".")[0].split("[")[0])
            if re.search(r"\{\{\s*" + base + r"\s*\}\}", body):
                unpiped += 1
    budget["boolean fields substituted bare, so they render True/False"] = unpiped

    # ---- closure: every bound template must exist and have a body ---------------------------------
    for path, entry in paths.items():
        tname = (entry or {}).get("template")
        if not tname:
            continue
        if not (TEMPLATES / tname / "template.j2").is_file():
            fail("a bound path whose template has no body",
                 f"{path} -> {tname} (it would be offered, then fail on Apply)")

    return bad, budget


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--baseline", action="store_true", help="record the current budget counts as tolerated")
    args = ap.parse_args()

    bad, budget = check()
    try:
        base = json.loads(BASELINE.read_text()).get("budgets") or {}
    except (OSError, ValueError):
        base = {}

    print("INVARIANTS — must be zero\n")
    if not bad:
        print("  all clear")
    for rule, hits in sorted(bad.items()):
        print(f"  {len(hits):5d}  {rule}")
        for h in hits[:4]:
            print(f"           {h}")
        if len(hits) > 4:
            print(f"           … and {len(hits) - 4} more")

    print("\nBUDGETS — cannot be zero yet, must not grow\n")
    regressed = []
    for name, count in sorted(budget.items()):
        was = base.get(name)
        mark = "" if was is None else (f"  (was {was})" if was != count else "  (unchanged)")
        print(f"  {count:5d}  {name}{mark}")
        if was is not None and count > was:
            regressed.append(f"{name}: {was} -> {count}")

    if args.baseline:
        write_catalog(BASELINE, {"budgets": budget,
                                 "note": "counts that cannot be zero yet; a rise fails the check"}, sort=True)
        print(f"\nrecorded {BASELINE.name}")
        return 0
    if bad:
        print(f"\nFAIL: {sum(len(v) for v in bad.values())} invariant violation(s)")
        return 1
    if regressed:
        print("\nFAIL: a budget grew — " + "; ".join(regressed))
        return 1
    print("\nthe three catalogs fit: no invariant violated, no budget grown")
    return 0


if __name__ == "__main__":
    sys.exit(main())
