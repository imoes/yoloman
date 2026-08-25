"""One setting, one value set — copy across where only one of the two catalogs has evidence.

    python -m bossman.tools.sync_value_sets [--write]

439 config files carry both a directive catalog and a bound template. Where the two BOTH state a value set and
disagree, `audit_value_agreement` records it and `settle_value_disagreements` decides against the man page.
This handles the other, larger case: **only one side has a set at all** — 29 keys where only the directive
does, 9 where only the template does. The same setting is then a dropdown in one editor and a text box in the
other, and which one the operator meets depends on the codec classification:

    /etc/freeipmi/ipmiseld.conf  driver-type      directive KCS BT SMIC INTERFACE   template —
    /etc/audit/plugins.d/laurel.conf  format      directive —                        template string json

Copying is safe in a way that deciding is not: nothing is deleted, nothing is invented, and the evidence
already exists — one catalog simply did not receive it. `enum_open` and the labels travel WITH the values,
because a set that is open on one side is the same open set on the other; copying the values and dropping the
"these are only suggestions" mark would turn a hedge into a claim.

It also finishes a rule the directive pass already applied: **a set of fewer than two options is not a
choice.** The directive catalog had 361; the template schemas still have 4, all of them single examples
(`logfacility: ["LOG_USER"]` whose description reads "e.g., LOG_USER, LOG_DAEMON").
"""

from __future__ import annotations

import argparse
import json

from bossman.tools._jsonio import write_catalog
from bossman.tools._paths import configs_dir
from bossman.tools._valuesets import normalise

CONFIGS = configs_dir(__file__)
TEMPLATES = CONFIGS / "config_templates"
DIRECTIVES = CONFIGS / "config_directives.json"
INDEX = CONFIGS / "config_template_index.json"
RECORD = CONFIGS / "value_set_sync.json"


def _dset(spec: dict) -> list | None:
    for k in ("values", "enum"):
        got = spec.get(k)
        if isinstance(got, list) and got:
            return got
    return None


def run() -> tuple[list[dict], list[dict]]:
    directives = json.loads(DIRECTIVES.read_text())
    paths = (json.loads(INDEX.read_text()).get("base") or {}).get("paths") or {}
    copied: list[dict] = []
    dropped: list[dict] = []
    dirty_directives = False
    dirty_templates: set[str] = set()
    schemas: dict[str, dict] = {}

    def schema_of(name: str) -> dict | None:
        if name not in schemas:
            try:
                schemas[name] = json.loads((TEMPLATES / name / "schema.json").read_text())
            except (OSError, ValueError):
                schemas[name] = {}
        raw = schemas[name]
        props = raw.get("properties", raw) if isinstance(raw, dict) else {}
        return props if isinstance(props, dict) else None

    # A one-option set, on the template side. The directive pass already did its own 361.
    for d in sorted(p for p in TEMPLATES.iterdir() if p.is_dir()):
        props = schema_of(d.name)
        if not props:
            continue
        for key, spec in props.items():
            if not isinstance(spec, dict):
                continue
            before = spec.get("enum")
            why = normalise(spec, "template")
            if why:
                dropped.append({"where": f"template:{d.name}", "key": key, "was": before, "reason": why})
                dirty_templates.add(d.name)

    # …and on the directive side, for the same reason: an earlier pass's deduplication can leave one behind,
    # and copying a one-option set into the other catalog would spread it rather than fix it.
    for path, spec in directives.items():
        if not isinstance(spec, dict):
            continue
        for key, dspec in spec.items():
            if not isinstance(dspec, dict):
                continue
            before = _dset(dspec)
            why = normalise(dspec, "directive")
            if why:
                dropped.append({"where": f"directive:{path}", "key": key, "was": before, "reason": why})
                dirty_directives = True

    for path, spec in directives.items():
        entry = paths.get(path)
        tname = (entry or {}).get("template")
        if not tname or not isinstance(spec, dict):
            continue
        props = schema_of(tname)
        if not props:
            continue
        for key, dspec in spec.items():
            if not isinstance(dspec, dict):
                continue
            tspec = props.get(key)
            if not isinstance(tspec, dict):
                continue
            d_values, t_values = _dset(dspec), tspec.get("enum")
            if d_values and not t_values:
                tspec["enum"] = list(d_values)
                # The MARK AND THE LABELS TRAVEL WITH THE VALUES. Copying an open set as a closed menu would
                # turn "these are suggestions" into "these are the only values" — the exact claim the
                # enum_open sweep exists to stop.
                if dspec.get("enum_open"):
                    tspec["enum_open"] = True
                labels = dspec.get("value_labels")
                if isinstance(labels, dict) and labels:
                    tspec["enum_labels"] = dict(labels)
                dirty_templates.add(tname)
                copied.append({"path": path, "key": key, "direction": "directive -> template",
                               "template": tname, "values": list(d_values),
                               "open": bool(dspec.get("enum_open"))})
            elif t_values and not d_values:
                dspec["values"] = list(t_values)
                if tspec.get("enum_open"):
                    dspec["enum_open"] = True
                labels = tspec.get("enum_labels")
                if isinstance(labels, dict) and labels:
                    dspec["value_labels"] = dict(labels)
                dirty_directives = True
                copied.append({"path": path, "key": key, "direction": "template -> directive",
                               "template": tname, "values": list(t_values),
                               "open": bool(tspec.get("enum_open"))})

    return copied, dropped, (dirty_directives, dirty_templates, directives, schemas)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--show", type=int, default=12)
    args = ap.parse_args()

    copied, dropped, (dirty_dir, dirty_tpl, directives, schemas) = run()
    print(f"{len(copied)} value set(s) copied to the catalog that lacked one")
    for row in copied[: args.show]:
        mark = " (open)" if row["open"] else ""
        print(f"    {row['direction']:22s} {row['path']} :: {row['key']}  {row['values'][:5]}{mark}")
    print(f"\n{len(dropped)} one-option set(s) dropped from template schemas")
    for row in dropped[: args.show]:
        print(f"    {row['where']} :: {row['key']}  was {row['was']}")

    if not args.write:
        print("\n(no --write — catalogs untouched)")
        return 0
    if dirty_dir:
        write_catalog(DIRECTIVES, directives, sort=True)
    for name in sorted(dirty_tpl):
        (TEMPLATES / name / "schema.json").write_text(json.dumps(schemas[name], indent=2) + "\n")
    write_catalog(RECORD, {"copied": copied, "dropped": dropped}, sort=False)
    print(f"\nwrote {len(dirty_tpl)} template schema(s), the directive catalog and {RECORD.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
