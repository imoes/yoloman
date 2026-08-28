"""A schema whose `type` is a sentence, a fragment, or a whole nested object.

    python -m bossman.tools.fix_broken_types [--write]

`check_catalog_fit` found 15 fields whose declared type is not a type at all — generation damage that no
earlier pass looked for, because every pass asked about VALUES:

    designate-agent.conf  description   type = "Port the agent listens on for incoming requests."
    designate-agent.conf  bind_port     type = ":{"
    81voltd               port          type = "number|list"
    chrony-vmware         time_source_path  type = "string|null"
    pagure_ci             builders.items    type = {"type": "string", "default": "docker", …}

The serving layer passes an unknown word through, so the editor asks its renderer for a control called
`"Port the agent listens on for incoming requests."` and gets the text-box fallback. It happens to be
harmless — a text box is the safe default — which is exactly why nobody noticed.

THE DEFAULT IS THE WITNESS, in that order:

  1. the type is a nested SPEC (`{"type": "string", …}`) — the generator wrote the whole field twice; the
     inner spec is the field, so it is unwrapped
  2. a UNION (`number|list`, `string|null`) resolves to the permissive member, the same rule the serving
     layer already applies to `bool|string`: a text box accepts what a number field would refuse
  3. otherwise the JSON type of the field's own `default` decides — a bool default means bool, a number
     means number, a list means list
  4. and with no default either, `string`. A text box is what the editor was already showing.

Nothing is guessed about the field's MEANING; only about which control renders it, where the wrong answer
today is "the fallback" and the right answer is the same fallback said out loud.
"""

from __future__ import annotations

import argparse
import json

from bossman.tools._jsonio import write_catalog
from bossman.tools._paths import configs_dir

CONFIGS = configs_dir(__file__)
TEMPLATES = CONFIGS / "config_templates"
DIRECTIVES = CONFIGS / "config_directives.json"
RECORD = CONFIGS / "broken_types_fixed.json"

KNOWN = {"string", "int", "number", "bool", "list", "object", "enum", "path", "secret", "float",
         "boolean", "integer", "array", "flat_map", "bool|string", "string|bool"}

#: Which member of a union wins: the one whose control accepts the other's values.
PERMISSIVE = ["string", "object", "list", "number", "int", "bool"]


def from_default(default: object) -> str:
    if isinstance(default, bool):
        return "bool"
    if isinstance(default, (int, float)):
        return "number"
    if isinstance(default, list):
        return "list"
    if isinstance(default, dict):
        return "object"
    return "string"


def repair(spec: dict) -> tuple[str, str] | None:
    """(new type, why) or None when the type is fine."""
    typ = spec.get("type")
    if isinstance(typ, dict):
        # The generator wrote the field spec twice, one nested in the other's `type`. The inner one IS the
        # field: lift it, so nothing about the field is invented.
        inner = typ
        for key, value in inner.items():
            if key != "type" or isinstance(value, str):
                spec.setdefault(key, value)
        got = inner.get("type")
        return (got if isinstance(got, str) and got in KNOWN else from_default(spec.get("default")),
                "the type held a whole nested spec; the inner one is the field")
    if not isinstance(typ, str) or not typ:
        return from_default(spec.get("default")), "no type at all; taken from the default's JSON type"
    if typ in KNOWN:
        return None
    parts = [p.strip().lower() for p in typ.split("|")]
    if len(parts) > 1 and all(p in {"string", "null", "number", "int", "list", "bool", "object"} for p in parts):
        for candidate in PERMISSIVE:
            if candidate in parts:
                return candidate, f"union {typ!r} resolved to its permissive member"
        return "string", f"union {typ!r} of nothing renderable"
    return (from_default(spec.get("default")),
            f"the type word {typ[:40]!r} is not a type; taken from the default's JSON type")


def run() -> list[dict]:
    fixed: list[dict] = []
    for d in sorted(p for p in TEMPLATES.iterdir() if p.is_dir()):
        f = d / "schema.json"
        try:
            schema = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        props = schema.get("properties", schema) if isinstance(schema, dict) else {}
        if not isinstance(props, dict):
            continue
        touched = False
        for key, spec in props.items():
            if not isinstance(spec, dict):
                continue
            got = repair(spec)
            if got is None:
                continue
            new, why = got
            fixed.append({"where": f"template:{d.name}", "key": key,
                          "was": spec.get("type") if isinstance(spec.get("type"), str) else "<nested spec>",
                          "now": new, "reason": why})
            spec["type"] = new
            touched = True
        if touched:
            f.write_text(json.dumps(schema, indent=2) + "\n")

    directives = json.loads(DIRECTIVES.read_text())
    dirty = False
    for path, spec in directives.items():
        if not isinstance(spec, dict):
            continue
        for key, entry in spec.items():
            if not isinstance(entry, dict):
                continue
            got = repair(entry)
            if got is None:
                continue
            new, why = got
            fixed.append({"where": f"directive:{path}", "key": key,
                          "was": entry.get("type") if isinstance(entry.get("type"), str) else "<nested spec>",
                          "now": new, "reason": why})
            entry["type"] = new
            dirty = True
    if dirty:
        write_catalog(DIRECTIVES, directives, sort=True)
    return fixed


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()
    if not args.write:
        keep = {d.name: (d / "schema.json").read_text()
                for d in TEMPLATES.iterdir() if d.is_dir() and (d / "schema.json").is_file()}
        keep_dir = DIRECTIVES.read_text()
        fixed = run()
        for name, text in keep.items():
            (TEMPLATES / name / "schema.json").write_text(text)
        DIRECTIVES.write_text(keep_dir)
    else:
        fixed = run()
    print(f"{len(fixed)} field(s) whose declared type was not a type")
    for row in fixed:
        print(f"    {row['where']:34s} {row['key']:24s} {str(row['was'])[:34]!r} -> {row['now']!r}")
        print(f"        {row['reason']}")
    if args.write:
        write_catalog(RECORD, {"fixed": fixed}, sort=False)
        print(f"\nwrote the catalogs and {RECORD.name}")
    else:
        print("\n(no --write — catalogs untouched)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
