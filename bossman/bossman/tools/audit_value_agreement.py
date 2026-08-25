"""Do the two catalogs agree about the same setting? Recorded, because a contradiction nobody sees is worse
than one that is written down.

    python -m bossman.tools.audit_value_agreement [--write]

439 config files carry BOTH a directive catalog (the per-key merge path, `config_directives.json`) and a bound
whole-file template. That overlap is known and is not itself the defect — the defect is that for 9 keys the
two state DIFFERENT value sets for the same setting:

    /etc/redis/redis.conf loglevel      directive  debug verbose notice warning
                                        template   debug verbose notice warning NOTHING
    /etc/freeipmi/… privilege-level     directive  CALLBACK USER OPERATOR ADMINISTRATOR
                                        template   USER OPERATOR ADMIN
    /etc/default/console-setup CODESET  directive  Arm …          template  Armenian …

Which set the operator sees depends on which editor opened the file, and that in turn depends on the codec
classification — so re-classifying one file silently changes the dropdown. That is the second law of this
project's own rules: never two views with contradictory state for one object.

THIS TOOL DOES NOT PICK A WINNER. Neither catalog is systematically right — spot-checking the nine, the
directive is correct for freeipmi's privilege levels and redis's log levels, and the template is correct for
console-setup's codesets. Deciding each needs the man page, which is mining work; asserting one side because
it is usually right would be exactly the guess-shaped-like-a-fix this codebase keeps finding. So the
disagreement is RECORDED, with both sets, for a later pass that has a source.
"""

from __future__ import annotations

import argparse
import json

from bossman.tools._jsonio import write_catalog
from bossman.tools._paths import configs_dir

CONFIGS = configs_dir(__file__)
RECORD = CONFIGS / "value_set_disagreements.json"


def _values(spec: dict) -> list | None:
    for key in ("values", "enum"):
        got = spec.get(key)
        if isinstance(got, list) and got:
            return got
    return None


def audit() -> dict:
    directives = json.loads((CONFIGS / "config_directives.json").read_text())
    index = json.loads((CONFIGS / "config_template_index.json").read_text())
    paths = (index.get("base") or {}).get("paths") or {}
    tpl_root = CONFIGS / "config_templates"

    both = 0
    rows = []
    for path, spec in directives.items():
        entry = paths.get(path)
        template = (entry or {}).get("template")
        if not template or not isinstance(spec, dict):
            continue
        both += 1
        schema_file = tpl_root / template / "schema.json"
        try:
            schema = json.loads(schema_file.read_text())
        except (OSError, ValueError):
            continue
        props = schema.get("properties", schema) if isinstance(schema, dict) else {}
        if not isinstance(props, dict):
            continue
        for key, dspec in spec.items():
            if not isinstance(dspec, dict):
                continue
            dvals = _values(dspec)
            tspec = props.get(key)
            tvals = _values(tspec) if isinstance(tspec, dict) else None
            if not dvals or not tvals:
                continue
            # Compared as SETS of strings: order is presentation, and "3" vs 3 is the same value written by
            # two writers. A difference that survives both normalisations is a real disagreement.
            if {str(v) for v in dvals} == {str(v) for v in tvals}:
                continue
            only_d = sorted({str(v) for v in dvals} - {str(v) for v in tvals})
            only_t = sorted({str(v) for v in tvals} - {str(v) for v in dvals})
            rows.append({
                "path": path, "key": key, "template": template,
                "directive_values": [str(v) for v in dvals],
                "template_values": [str(v) for v in tvals],
                "only_in_directive": only_d, "only_in_template": only_t,
                # A set that is a strict SUBSET is the more actionable shape: one side is simply missing
                # values the other names, rather than the two naming different things.
                "shape": ("template is a subset of the directive" if not only_t else
                          "directive is a subset of the template" if not only_d else
                          "each names values the other does not"),
            })
    return {"paths_with_both": both, "disagreements": rows}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()
    result = audit()
    print(f"{result['paths_with_both']} paths carry BOTH a directive catalog and a bound template")
    print(f"{len(result['disagreements'])} keys where the two state DIFFERENT value sets\n")
    for row in result["disagreements"]:
        print(f"  {row['path']} :: {row['key']}   [{row['shape']}]")
        if row["only_in_directive"]:
            print(f"      only the directive has: {', '.join(row['only_in_directive'])}")
        if row["only_in_template"]:
            print(f"      only the template has:  {', '.join(row['only_in_template'])}")
    if args.write:
        write_catalog(RECORD, result, sort=False)
        print(f"\nwrote {RECORD.name}")
    else:
        print("\n(no --write — nothing recorded)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
