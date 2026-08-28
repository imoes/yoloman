"""Where a file spells booleans yes/no, a checkbox is the wrong control — give the field the two words.

    python -m bossman.tools.bool_vocabulary [--write]

The renderer no longer emits Python-cased booleans (`internal/modules/template_render.go` coerces them to
`true`/`false`), which is the right floor: `False` is never correct for any config file. But `false` is not
right for every file either, and the DIRECTIVE CATALOG says which ones — its own default for the same key is
the word that file uses.

Measured over the 585 bool-defaulted template fields with a directive counterpart:

    569  the directive also says true/false  ->  nothing to do, the floor already writes the right word
     16  the directive says yes/no           ->  a checkbox submits `true` and the file wants `yes`

So those 16 become a two-value set with the file's own words (`enum: ["yes","no"]`, `type: string`), which is
exactly what the directive catalog already does for 823 keys: the type says two-state, the values say which
literals. The control changes from a checkbox to a two-option dropdown — a small loss of prettiness against a
config the daemon actually accepts.

NOT DONE HERE: inventing a vocabulary. A field whose directive default is absent, or is prose
("false (or true if no listeners defined)"), is left alone — 8 of them — because the word the file wants is
then genuinely unknown and `false` from the floor is the best available answer.
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
RECORD = CONFIGS / "bool_vocabulary.json"

#: The pairs a config file might use. `true`/`false` is deliberately ABSENT: the renderer's floor already
#: writes those two words, so turning such a field into a dropdown would be churn with no change in output.
PAIRS = {
    "yes": ("yes", "no"), "no": ("yes", "no"),
    "on": ("on", "off"), "off": ("on", "off"),
    "enabled": ("enabled", "disabled"), "disabled": ("enabled", "disabled"),
    "1": ("1", "0"), "0": ("1", "0"),
}


def pair_for(directive_default: object) -> tuple[str, str] | None:
    if directive_default in (None, ""):
        return None
    word = str(directive_default).strip().strip("'\"").lower()
    return PAIRS.get(word)


def run() -> tuple[list[dict], list[dict]]:
    directives = json.loads(DIRECTIVES.read_text())
    paths = (json.loads(INDEX.read_text()).get("base") or {}).get("paths") or {}
    changed: list[dict] = []
    left: list[dict] = []
    schemas: dict[str, dict] = {}
    dirty: set[str] = set()

    for path, spec in directives.items():
        tname = (paths.get(path) or {}).get("template")
        if not tname or not isinstance(spec, dict):
            continue
        if tname not in schemas:
            try:
                schemas[tname] = json.loads((TEMPLATES / tname / "schema.json").read_text())
            except (OSError, ValueError):
                schemas[tname] = {}
        raw = schemas[tname]
        props = raw.get("properties", raw) if isinstance(raw, dict) else {}
        if not isinstance(props, dict):
            continue
        for key, dspec in spec.items():
            if not isinstance(dspec, dict):
                continue
            tspec = props.get(key)
            if not isinstance(tspec, dict) or not isinstance(tspec.get("default"), bool):
                continue
            pair = pair_for(dspec.get("default"))
            if pair is None:
                left.append({"path": path, "template": tname, "key": key,
                             "template_default": tspec["default"],
                             "directive_default": dspec.get("default"),
                             "reason": "the directive gives no usable word, so the renderer's true/false "
                                       "floor is the best available answer"})
                continue
            was = tspec["default"]
            tspec["type"] = "string"
            tspec["enum"] = list(pair)
            tspec["default"] = pair[0] if was else pair[1]
            normalise(tspec, "template")
            dirty.add(tname)
            changed.append({"path": path, "template": tname, "key": key, "was": was,
                            "now": tspec.get("default"), "values": list(pair)})
    return changed, left, (dirty, schemas)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()
    changed, left, (dirty, schemas) = run()
    print(f"{len(changed)} field(s) given the file's own boolean words")
    for row in changed:
        print(f"    {row['template']:20s} {row['key']:26s} {row['was']} -> {row['now']!r}  {row['values']}")
    print(f"\n{len(left)} left to the renderer's true/false floor")
    for row in left[:8]:
        print(f"    {row['template']:20s} {row['key']:26s} directive default="
              f"{str(row['directive_default'])[:34]!r}")
    if args.write:
        for name in sorted(dirty):
            (TEMPLATES / name / "schema.json").write_text(json.dumps(schemas[name], indent=2) + "\n")
        write_catalog(RECORD, {"changed": changed, "left": left}, sort=False)
        print(f"\nwrote {len(dirty)} schema(s) and {RECORD.name}")
    else:
        print("\n(no --write — schemas untouched)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
