"""`debug={{ debug }}` with a boolean writes "False" — add the `| lower` a correct Jinja template would have.

    python -m bossman.tools.lower_literal_bools [--write]

gonja renders a bool Python-cased because Jinja2 does: `{{ debug }}` with false produces "False", which shell,
INI and YAML all reject or read as a non-empty (i.e. true) string. Coercing the value to a string in the
renderer was tried and REVERTED — a non-empty string is truthy, so `false | yes_no` returned "yes" and every
`{% if flag %}` took the wrong branch. Silently inverting a template's logic is worse than a capital F.

So the body is what is wrong, and only in one specific place. Classified over the corpus by how the body
USES each boolean-defaulted field:

    11 314  only inside {% if %} or behind a filter   the body is correct; nothing to do
       540  bare {{ var }} only                       writes False — THIS is the defect
        60  both                                      cannot be piped without changing the conditional's input
     1 426  the name never appears in the body        already recorded in template_withheld.json

For the 540, `{{ var }}` becomes `{{ var | lower }}`: measured through gonja, that renders "false"/"true".
Nothing is guessed — no vocabulary invented, no default rewritten, the value stays a bool so any future
conditional still works.

THE 60 ARE LEFT ALONE AND RECORDED. A field used both bare and in a conditional cannot be fixed this way: the
same variable would have to be a word in one place and a boolean in the other. Those need the value set that
names the file's words, which is a decision with evidence, not an edit.

And a file that wants `yes`/`no` is still not served by `lower` — that is what tools/bool_vocabulary.py is
for, and it has the directive catalog's own default as its witness.
"""

from __future__ import annotations

import argparse
import json
import re

from bossman.tools._jsonio import write_catalog
from bossman.tools._paths import configs_dir

CONFIGS = configs_dir(__file__)
TEMPLATES = CONFIGS / "config_templates"
RECORD = CONFIGS / "literal_bool_lowered.json"


def classify(body: str, field: str) -> str:
    """How the body uses this field: "bare", "guarded", "both" or "absent"."""
    # The BASE name: a field is declared `sites[].ssl` or `ui.enabled` while the body writes the loop
    # variable or the dotted path, so matching the full key would miss almost everything.
    base = re.escape(field.split(".")[0].split("[")[0])
    bare = bool(re.search(r"\{\{\s*" + base + r"\s*\}\}", body))
    # `{% if x %}`, `{% for … in x %}` — anything inside a statement block.
    in_block = bool(re.search(r"\{%[^%]*\b" + base + r"\b", body))
    # `{{ x | filter }}`, `{{ x.attr }}`, `{{ x[0] }}` — already shaped by something.
    piped = bool(re.search(r"\{\{\s*" + base + r"\s*[|.\[]", body))
    if bare and not in_block and not piped:
        return "bare"
    if bare:
        return "both"
    if in_block or piped:
        return "guarded"
    return "absent"


def _sample_value(sample: object, path: str) -> object:
    """Follow a dotted path into the sample. `prometheus.enabled` is one substitution, not two."""
    node = sample
    for part in path.split("."):
        if not isinstance(node, dict) or part not in node:
            return None
        node = node[part]
    return node


def _bare_bool_paths(body: str, sample: dict) -> list[str]:
    """Bare `{{ path }}` substitutions whose SAMPLE value is a JSON boolean.

    THE SAMPLE IS THE WITNESS, and it has to be: the schema-key pass below misses every nested field, because
    a dotted `{{ prometheus.enabled }}` looks "already shaped" to a rule keyed on the base name. Measured —
    after that pass, 28 of 130 rendered templates still contained a Python-cased boolean, every one of them
    from a dotted or indexed path. What the sample says renders as a bool IS a bool at render time.
    """
    out = []
    for path in set(re.findall(r"\{\{\s*([a-zA-Z_][\w.]*)\s*\}\}", body)):
        if isinstance(_sample_value(sample, path), bool):
            out.append(path)
    return sorted(out)


def run() -> tuple[list[dict], list[dict]]:
    lowered: list[dict] = []
    skipped: list[dict] = []
    for d in sorted(p for p in TEMPLATES.iterdir() if p.is_dir()):
        body_file = d / "template.j2"
        try:
            schema = json.loads((d / "schema.json").read_text())
            body = body_file.read_text()
        except (OSError, ValueError):
            continue
        props = schema.get("properties", schema) if isinstance(schema, dict) else {}
        if not isinstance(props, dict):
            continue
        new_body = body
        touched: list[str] = []
        for key, spec in props.items():
            if not isinstance(spec, dict) or not isinstance(spec.get("default"), bool):
                continue
            kind = classify(body, key)
            if kind == "both":
                skipped.append({"template": d.name, "key": key,
                                "reason": "used bare AND inside a block or behind a filter — piping it would "
                                          "change what the conditional receives; this one needs the file's "
                                          "words as a value set instead"})
                continue
            if kind != "bare":
                continue
            base = key.split(".")[0].split("[")[0]
            pattern = re.compile(r"\{\{\s*" + re.escape(base) + r"\s*\}\}")
            replaced, n = pattern.subn("{{ " + base + " | lower }}", new_body)
            if n:
                new_body = replaced
                touched.append(f"{base}×{n}")
                lowered.append({"template": d.name, "key": key, "occurrences": n})
        # SECOND PASS, from the sample: every bare substitution the sample proves renders a boolean,
        # including the dotted and indexed paths the schema-key pass cannot see.
        try:
            sample = json.loads((d / "sample.json").read_text())
        except (OSError, ValueError):
            sample = {}
        if isinstance(sample, dict):
            for path in _bare_bool_paths(new_body, sample):
                pattern = re.compile(r"\{\{\s*" + re.escape(path) + r"\s*\}\}")
                replaced, n = pattern.subn("{{ " + path + " | lower }}", new_body)
                if n:
                    new_body = replaced
                    lowered.append({"template": d.name, "key": path, "occurrences": n,
                                    "witness": "sample value is a boolean"})
        if new_body != body:
            body_file.write_text(new_body)
    return lowered, skipped


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--show", type=int, default=10)
    args = ap.parse_args()

    if not args.write:
        keep = {d.name: (d / "template.j2").read_text()
                for d in TEMPLATES.iterdir() if d.is_dir() and (d / "template.j2").is_file()}
        lowered, skipped = run()
        for name, text in keep.items():
            (TEMPLATES / name / "template.j2").write_text(text)
    else:
        lowered, skipped = run()

    print(f"{len(lowered)} bare boolean substitution(s) given `| lower`")
    for row in lowered[: args.show]:
        print(f"    {row['template']:26s} {row['key']:28s} ×{row['occurrences']}")
    print(f"\n{len(skipped)} left alone — used bare AND guarded")
    for row in skipped[: args.show]:
        print(f"    {row['template']:26s} {row['key']}")
    if args.write:
        write_catalog(RECORD, {"lowered": lowered, "skipped": skipped}, sort=False)
        print(f"\nwrote the bodies and {RECORD.name}")
    else:
        print("\n(no --write — bodies untouched)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
