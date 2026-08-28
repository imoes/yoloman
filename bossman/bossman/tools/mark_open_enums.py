"""An example is not an enumeration — mark the enums whose own description says so, instead of deleting them.

    python -m bossman.tools.mark_open_enums [--write]

The description extractor REFUSES to build an enum out of "(e.g., 'amd64', 'arm64')", because a dropdown from
an open set removes every value it does not list. The LLM enum stage has no such gate, and it ran first.
Measured on the corpus: **389 enumerated fields carry a description that marks its own values as an example
or hedges them** — and the damage is visible field by field:

    alien/target_arch      enum ['all','source','any']      desc "e.g., 'amd64', 'i386', 'all'"
    apcupsd_cgi/syslog     enum ['daemon','user']           desc "Common values: 'daemon', 'local0'-'local7'"
    0install/…items.type   enum ['version','trust']         desc "e.g., 'version','rating','age','trust',…"

A syslog-facility dropdown without local0-local7 does not merely look thin: the operator cannot enter the
value the file needs, and the template write path is whole-file.

DELETING THEM WOULD BE WRONG TOO. Several are correct sets that happen to be introduced with a hedge —
`ansible_core/defaults_fact_caching: jsonfile|memory|redis|yaml` really is Ansible's set, described as "Common
options". The suggestions are worth keeping.

So the fields are MARKED, not emptied: `enum_open: true` travels to the editor, which renders an input with a
datalist — the suggestions stay, and a value the catalog never learned can still be typed. That is the honest
control for a set nobody has closed.

Also fixed here because it is the same audit pass: enums containing the SAME VALUE TWICE
(`acl/permissions: ['r--', 'r--', 'rw-']`) — a menu with two identical entries.
"""

from __future__ import annotations

import argparse
import json
import re

from bossman.tools._jsonio import write_catalog
from bossman.tools._paths import configs_dir
from bossman.tools._valuesets import dedupe as _dedupe, normalise

CONFIGS = configs_dir(__file__)
TEMPLATES = CONFIGS / "config_templates"
DIRECTIVES = CONFIGS / "config_directives.json"
RECORD = CONFIGS / "open_enums.json"

#: The markers that say "these are examples" or "these are the common ones". Same vocabulary the description
#: extractor refuses on — one rule, applied there before an enum is built and here after one already was.
HEDGE = re.compile(r"\b(?:e\.?g\.?|i\.?e\.?|for\s+example|such\s+as|examples?|typically|usually|"
                   r"commonly|common)\b", re.I)

#: How far after the marker a value may appear and still count as introduced by it. The marker has to be
#: about THESE values: a description ending "e.g. see the manual" does not open a set listed before it.
_LOCALITY = 140


def hedged(description: str, values: list) -> str:
    """The hedge phrase that opens this value set, or "" when none does."""
    if not description or not values:
        return ""
    low = description.lower()
    for match in HEDGE.finditer(description):
        window = low[match.end():match.end() + _LOCALITY]
        if any(str(v).lower() in window for v in values[:6] if v not in (None, "")):
            return match.group(0)
    return ""


def sweep() -> tuple[list[dict], list[dict]]:
    """(opened, deduped) — the decisions, applied to the files on disk by the caller."""
    opened: list[dict] = []
    deduped: list[dict] = []

    def visit(container: dict, where: str, key_of_set: str) -> bool:
        touched = False
        for key, spec in container.items():
            if not isinstance(spec, dict):
                continue
            values = spec.get(key_of_set)
            if not isinstance(values, list) or not values:
                continue
            # THE SHARED INVARIANT, not a local dedupe. Deduplicating on its own CREATED one-option sets:
            # ['LOG_DAEMON','LOG_DAEMON'] became ['LOG_DAEMON'] after the pass that removes those had
            # already run, so two correct rules in the wrong order produced the thing both forbid.
            before = list(values)
            why = normalise(spec, "directive" if key_of_set == "values" else "template")
            values = spec.get(key_of_set)
            if why:
                deduped.append({"where": where, "key": key, "was": before,
                                "now": list(values) if isinstance(values, list) else None, "reason": why})
                touched = True
            if not isinstance(values, list) or not values:
                continue
            phrase = hedged(spec.get("description") or "", values)
            if phrase and not spec.get("enum_open"):
                spec["enum_open"] = True
                opened.append({"where": where, "key": key, "values": values, "marker": phrase,
                               "description": (spec.get("description") or "")[:160]})
                touched = True
        return touched

    for d in sorted(p for p in TEMPLATES.iterdir() if p.is_dir()):
        f = d / "schema.json"
        try:
            schema = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        props = schema.get("properties", schema) if isinstance(schema, dict) else {}
        if isinstance(props, dict) and visit(props, f"template:{d.name}", "enum"):
            f.write_text(json.dumps(schema, indent=2) + "\n")

    directives = json.loads(DIRECTIVES.read_text())
    dirty = False
    for path, spec in directives.items():
        if isinstance(spec, dict) and visit(spec, f"directive:{path}", "values"):
            dirty = True
    if dirty:
        write_catalog(DIRECTIVES, directives, sort=True)
    return opened, deduped


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--show", type=int, default=10)
    args = ap.parse_args()

    if not args.write:
        # Report without touching anything: the sweep mutates in place, so the dry run reads a copy.
        import copy
        original_tpl = {d.name: (d / "schema.json").read_text()
                        for d in TEMPLATES.iterdir() if d.is_dir() and (d / "schema.json").is_file()}
        original_dir = DIRECTIVES.read_text()
        opened, deduped = sweep()
        for name, text in original_tpl.items():
            (TEMPLATES / name / "schema.json").write_text(text)
        DIRECTIVES.write_text(original_dir)
        del copy
    else:
        opened, deduped = sweep()

    print(f"{len(opened)} field(s) marked enum_open — an example or hedged set presented as a closed menu")
    for row in opened[: args.show]:
        print(f"    {row['where']} :: {row['key']}   [{row['marker']}]")
        print(f"        {row['values'] if len(str(row['values'])) < 70 else str(row['values'])[:67] + '…'}")
    print(f"\n{len(deduped)} field(s) had a DUPLICATE value removed")
    for row in deduped[: args.show]:
        print(f"    {row['where']} :: {row['key']}   {row['was']} -> {row['now']}")
    if args.write:
        write_catalog(RECORD, {"opened": opened, "deduped": deduped}, sort=False)
        print(f"\nwrote the catalogs and {RECORD.name}")
    else:
        print("\n(no --write — catalogs untouched)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
