"""The directive catalog's value sets: read the ones its descriptions already state, drop the ones that are
not choices.

    python -m bossman.tools.directive_values            # report, write nothing
    python -m bossman.tools.directive_values --write

`config_directives.json` is the per-key catalog behind the gpedit/OU policy editor and the codec MERGE write
path — the common case, and the one the template work has not touched. Measured: 43 463 keys over 2130 paths,
**99.5% carry a description** and only **10.6%** carry a value set.

TWO RULES, both already proven on the template side (tools/enums_from_descriptions), applied here so the two
catalogs stop disagreeing about what an enumerable setting is:

  1. THE DESCRIPTION OFTEN STATES THE SET. "Verbosity level for server logs. Options: debug, info, notice,
     warning, error, crit, alert, emerg" — 151 keys gain a real dropdown from text that was already there.
     Same extractor, same gates: an example is not an enumeration, a hedge is not an allowed set, a list is
     never truncated, and a default outside the set refuses.

  2. FEWER THAN TWO VALUES IS NOT AN ENUM, and here it is actively harmful. Measured, 361 keys offer exactly
     ONE option — `AllowOverride: ["None"]`, when Apache also accepts All, AuthConfig, FileInfo and more. A
     one-option dropdown does not merely look odd: it REMOVES every legal value from the operator's reach,
     which is the same harm as an example list turned into a menu. The field becomes free text again, keeps
     its description, and the drop is recorded.

WHAT IS DELIBERATELY LEFT ALONE:

  * `type: bool` with `values: ["On", "Off"]` — 823 keys, and they are RIGHT. The type says two-state, the
    values say which literals the file wants; a checkbox would submit `true` where the file needs `On`.
  * `type: list` with an item value set — a multi-select, not a single choice.
  * multi-word values. `Require: ["all denied", "all granted"]`, `isolation_level: ["repeatable read"]`,
    `map to guest: ["bad user"]` are the real values of Apache, SQL and Samba. A "looks like prose" filter
    flagged 26 of these and 25 were correct — which is why there is no such filter here.

Every decision, taken or refused, is recorded in configs/directive_values_decisions.json.
"""

from __future__ import annotations

import argparse
import json

from bossman.tools._jsonio import write_catalog
from bossman.tools._paths import configs_dir
from bossman.tools.enums_from_descriptions import extract

CONFIGS = configs_dir(__file__)
DIRECTIVES = CONFIGS / "config_directives.json"
RECORD = CONFIGS / "directive_values_decisions.json"

#: The key holding a value set. `values` is the directive catalog's own name for it; `enum` appears too and is
#: read as a synonym rather than migrated — the serving side already accepts both, and renaming 4596 keys to
#: settle a spelling would be a change nobody can see.
VALUE_KEYS = ("values", "enum")


def _value_set(spec: dict) -> list | None:
    for key in VALUE_KEYS:
        got = spec.get(key)
        if isinstance(got, list):
            return got
    return None


def process(catalog: dict) -> tuple[dict, list[dict]]:
    """Apply both rules. Returns (catalog, decisions)."""
    decisions: list[dict] = []
    for path, spec in catalog.items():
        if not isinstance(spec, dict):
            continue
        names = {k.lower() for k in spec}
        for key, entry in spec.items():
            if not isinstance(entry, dict):
                continue
            values = _value_set(entry)

            # RULE 2 FIRST, and rule 1 then gets its turn on the same key — deliberately. Dropping
            # `["fast"]` and reading `["fast", "slow"]` out of the description is the better outcome: the
            # field becomes a real dropdown instead of free text. The record shows both steps in order, so
            # "dropped a one-option set, then read the stated set" is readable rather than contradictory.
            if values is not None and len(values) < 2:
                for name in VALUE_KEYS:
                    entry.pop(name, None)
                decisions.append({
                    "path": path, "key": key, "action": "dropped", "was": values,
                    "reason": "a set of fewer than two options is not a choice — the dropdown offered one "
                              "value and hid every other legal one; the field is free text with its "
                              "description intact",
                })
                values = None

            if values is not None:
                continue                      # already a real set; nothing to decide
            if entry.get("type") not in ("string", None, "enum"):
                continue                      # bool/int/list carry their own control
            labels: dict[str, str] = {}
            got, why = extract(entry.get("description") or "", names, labels, key)
            if not got:
                decisions.append({"path": path, "key": key, "action": "none", "reason": why})
                continue
            default = entry.get("default")
            if default not in (None, "") and str(default) not in got:
                decisions.append({"path": path, "key": key, "action": "none", "candidate": got,
                                  "reason": f"the recorded default {default!r} is not in the extracted set"})
                continue
            entry["values"] = got
            decision = {"path": path, "key": key, "action": "added", "values": got, "reason": why}
            if labels and not set(got) - set(labels):
                entry["value_labels"] = {v: labels[v] for v in got}
                decision["labels"] = entry["value_labels"]
            decisions.append(decision)
    return catalog, decisions


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--write", action="store_true", help="write the catalog (default: report only)")
    ap.add_argument("--show", type=int, default=12)
    args = ap.parse_args()

    catalog = json.loads(DIRECTIVES.read_text())
    before = sum(1 for s in catalog.values() if isinstance(s, dict)
                 for e in s.values() if isinstance(e, dict) and _value_set(e))
    catalog, decisions = process(catalog)
    after = sum(1 for s in catalog.values() if isinstance(s, dict)
                for e in s.values() if isinstance(e, dict) and _value_set(e))

    added = [d for d in decisions if d["action"] == "added"]
    dropped = [d for d in decisions if d["action"] == "dropped"]
    print(f"keys with a value set: {before} -> {after}")
    print(f"  added from their own description : {len(added)}")
    print(f"  dropped as a one-option set      : {len(dropped)}")
    print(f"  no change                        : {len(decisions) - len(added) - len(dropped)}")
    for d in added[: args.show]:
        shape = d.get("labels") or d["values"]
        print(f"    + {d['key']:28s} {shape}")
    for d in dropped[: args.show // 2]:
        print(f"    - {d['key']:28s} was {d['was']}")

    if not args.write:
        print("\n(no --write — catalog untouched)")
        return 0
    write_catalog(DIRECTIVES, catalog, sort=True)
    write_catalog(RECORD, {"decisions": decisions}, sort=False)
    print(f"\nwrote {DIRECTIVES.name} and {RECORD.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
