"""Every template whose rendered output would end without a newline gets one — a sweep, no model involved.

    .venv-host/bin/python -m bossman.tools.ensure_template_newlines [--dry-run]

Rule: tools.template_invariants.ensure_final_newline (decided on the text rendered from the schema's defaults).
qualify_packages applies it to every package it processes; this sweep fixes the templates written before.
"""

from __future__ import annotations

import argparse
import shutil
import tempfile
from pathlib import Path

from bossman.tools import qualify_packages as Q
from bossman.tools.template_invariants import ensure_final_newline


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    changed = 0
    for d in sorted(Q.TEMPLATES_DIR.iterdir()):
        if not (d / "template.j2").is_file():
            continue
        if args.dry_run:
            with tempfile.TemporaryDirectory() as tmp:
                copy = Path(tmp) / d.name
                shutil.copytree(d, copy)
                changed += ensure_final_newline(copy)
        else:
            changed += ensure_final_newline(d)
    print(f"{changed} template(s) {'would get' if args.dry_run else 'got'} a final newline")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
