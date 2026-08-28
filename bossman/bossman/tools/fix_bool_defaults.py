"""A JSON boolean sitting in a text field — rendered into the file it writes `True`, which no parser accepts.

    python -m bossman.tools.fix_bool_defaults [--write]

25 template fields are typed `string` and carry `default: true`/`false` — a JSON boolean, not the word the
config file wants. `template_render` substitutes it verbatim, so the file receives `True` with a capital T,
and shell, INI and YAML parsers alike reject it (or read it as a non-empty string, i.e. always true).

THE FILE'S OWN VOCABULARY IS IN ITS SAMPLE. `sample.json` carries a working example value for each field, and
all 25 have a string there:

    heimdal-kdc/kdc_enabled     default True   sample 'yes'    ->  "yes"
    parsec-service/allow_root   default False  sample 'false'  ->  "false"
    apcupsd/nis_enabled         default True   sample 'on'     ->  "on"

So the pair is LEARNED, not assumed: a sample of `yes` means this file spells booleans yes/no, and the
default's truth value is mapped through that pair. Taking the sample AS the default would be wrong — measured,
`dyn-netconf/dhcp` has `default: true` beside `sample: 'false'`, and the sample is an example of the syntax,
not a statement about the default.

AND WHERE THE SAMPLE IS NOT A BOOLEAN WORD, THIS ABSTAINS. `gallery-dl/zip` samples
`'gallery-dl-{id}.zip'` and `openssh_client/control_master` samples `'auto'`: those fields are not two-state
at all, so their boolean default is simply wrong and no vocabulary can repair it. The default is dropped —
the description survives, and an empty field is honest where a wrong word is not.
"""

from __future__ import annotations

import argparse
import json

from bossman.tools._jsonio import write_catalog
from bossman.tools._paths import configs_dir

CONFIGS = configs_dir(__file__)
TEMPLATES = CONFIGS / "config_templates"
RECORD = CONFIGS / "bool_default_fixes.json"

#: The boolean vocabularies a config file might use, keyed by every word that identifies the pair. Only these
#: three: measured, they cover every sample in the corpus, and inventing a fourth (`1`/`0`, `enable`/`disable`)
#: on no evidence is how a guess enters a catalog.
VOCABULARIES = {
    "yes": ("yes", "no"), "no": ("yes", "no"),
    "true": ("true", "false"), "false": ("true", "false"),
    "on": ("on", "off"), "off": ("on", "off"),
}


def vocabulary_of(sample: object) -> tuple[str, str] | None:
    """The (true_word, false_word) this file uses, learned from a sample value, or None."""
    if not isinstance(sample, str):
        return None
    return VOCABULARIES.get(sample.strip().lower())


def run() -> tuple[list[dict], list[dict]]:
    fixed: list[dict] = []
    dropped: list[dict] = []
    for d in sorted(p for p in TEMPLATES.iterdir() if p.is_dir()):
        schema_file, sample_file = d / "schema.json", d / "sample.json"
        try:
            schema = json.loads(schema_file.read_text())
        except (OSError, ValueError):
            continue
        try:
            sample = json.loads(sample_file.read_text())
        except (OSError, ValueError):
            sample = {}
        props = schema.get("properties", schema) if isinstance(schema, dict) else {}
        if not isinstance(props, dict):
            continue
        touched = False
        for key, spec in props.items():
            if not isinstance(spec, dict):
                continue
            default = spec.get("default")
            # A JSON boolean in a field the file reads as TEXT. A field genuinely typed bool is fine — the
            # renderer knows what to write for it.
            if not isinstance(default, bool) or spec.get("type") not in ("string", None):
                continue
            pair = vocabulary_of(sample.get(key) if isinstance(sample, dict) else None)
            if pair is None:
                spec.pop("default", None)
                dropped.append({"template": d.name, "key": key, "was": default,
                                "sample": sample.get(key) if isinstance(sample, dict) else None,
                                "reason": "the sample is not a boolean word, so this field is not two-state "
                                          "and no vocabulary can repair its boolean default; an empty field "
                                          "is honest where a wrong word is not"})
                touched = True
                continue
            spec["default"] = pair[0] if default else pair[1]
            fixed.append({"template": d.name, "key": key, "was": default, "now": spec["default"],
                          "sample": sample.get(key), "vocabulary": list(pair)})
            touched = True
        if touched:
            schema_file.write_text(json.dumps(schema, indent=2) + "\n")
    return fixed, dropped


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()

    if not args.write:
        keep = {d.name: (d / "schema.json").read_text()
                for d in TEMPLATES.iterdir() if d.is_dir() and (d / "schema.json").is_file()}
        fixed, dropped = run()
        for name, text in keep.items():
            (TEMPLATES / name / "schema.json").write_text(text)
    else:
        fixed, dropped = run()

    print(f"{len(fixed)} boolean default(s) written in the file's own vocabulary")
    for row in fixed:
        print(f"    {row['template']:22s} {row['key']:26s} {row['was']} -> {row['now']!r}   "
              f"(sample {row['sample']!r})")
    print(f"\n{len(dropped)} dropped — the sample is not a boolean word")
    for row in dropped:
        print(f"    {row['template']:22s} {row['key']:26s} was {row['was']}   sample {row['sample']!r}")
    if args.write:
        write_catalog(RECORD, {"fixed": fixed, "dropped": dropped}, sort=False)
        print(f"\nwrote the schemas and {RECORD.name}")
    else:
        print("\n(no --write — schemas untouched)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
