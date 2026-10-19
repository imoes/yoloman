"""Every template schema's defaults and enum values in the field's declared type — a sweep, no model involved.

    .venv-host/bin/python -m bossman.tools.normalize_schema_types [--dry-run]

The rule is services.schema_defaults.normalize_types (numeric strings in a number field become numbers; a number
field holding a word becomes a string field). qualify_packages applies it to every package it processes; this
sweep brings the templates written before that up to it.
"""

from __future__ import annotations

import argparse
import json

from bossman.services.schema_defaults import normalize_types
from bossman.tools import qualify_packages as Q


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    templates = fields = 0
    for d in sorted(Q.TEMPLATES_DIR.iterdir()):
        f = d / "schema.json"
        if not f.is_file():
            continue
        try:
            schema = json.loads(f.read_text())
        except ValueError:
            continue
        if not isinstance(schema, dict):
            continue
        props = schema["properties"] if isinstance(schema.get("properties"), dict) else schema
        n = normalize_types(props)
        # The sample follows the field type too: a bool in a number field rendered "True" where the file wants 1
        # (stubby: round_robin_upstreams: True — "Could not parse config file").
        sf = d / "sample.json"
        try:
            sample = json.loads(sf.read_text()) if sf.is_file() else None
        except ValueError:
            sample = None
        if isinstance(sample, dict):
            moved = 0
            for k, spec in props.items():
                if isinstance(spec, dict) and spec.get("type") in ("number", "integer") and isinstance(sample.get(k), bool):
                    sample[k] = int(sample[k])
                    moved += 1
            if moved and not args.dry_run:
                sf.write_text(json.dumps(sample, indent=2) + "\n")
            fields += moved
        if n:
            templates += 1
            fields += n
            if not args.dry_run:
                f.write_text(json.dumps(schema, indent=2) + "\n")  # the pipeline's format (ASCII escapes)
    print(f"{fields} field(s) in {templates} template(s) {'would be' if args.dry_run else ''} normalized")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
