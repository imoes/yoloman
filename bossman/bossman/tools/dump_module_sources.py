"""Dumps the translation templates for the Starlark module library
(docs/plan.md Block G8): for every module of the in-scope collections,
one JSON file <out_dir>/<fqcn>.json containing the ansible-doc metadata
(options/argspec, description, examples) plus the original Python source
— everything the translating LLM needs, pre-extracted so the Bossman
container never needs ansible installed.

Run on a host with ansible-core + the collections installed:

    python3 scripts/dump_module_sources.py [--out ../configs/module_sources]

Deterministic output (sorted keys) so re-runs are diffable. The dump is a
generated artifact — gitignored, regenerated when collections update.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

COLLECTIONS = ["posix", "community.crypto", "community.docker", "community.general"]

# ansible-doc -j for hundreds of names at once is fine, but keep chunks
# bounded so one broken module's stderr noise stays attributable.
CHUNK = 40


def run_json(argv: list[str]) -> dict:
    proc = subprocess.run(argv, capture_output=True, text=True)
    if proc.returncode != 0 and not proc.stdout.strip():
        raise SystemExit(f"{' '.join(argv[:3])}... failed: {proc.stderr.strip()[:500]}")
    return json.loads(proc.stdout)


def list_modules(collection: str) -> list[str]:
    """Every module fqcn in one collection (ansible-doc -l already
    excludes non-module plugins by default)."""
    data = run_json(["ansible-doc", "-l", "-j", collection])
    return sorted(data.keys())


def collection_roots() -> list[Path]:
    """Where installed collections live, per ansible-galaxy itself."""
    proc = subprocess.run(["ansible-galaxy", "collection", "list", "--format", "json"], capture_output=True, text=True)
    roots: list[Path] = []
    if proc.returncode == 0 and proc.stdout.strip():
        try:
            roots = [Path(p) for p in json.loads(proc.stdout)]
        except json.JSONDecodeError:
            pass
    return roots or [Path.home() / ".ansible/collections/ansible_collections"]


def find_source(roots: list[Path], fqcn: str, doc: dict | None = None) -> str | None:
    ns, coll, name = fqcn.split(".", 2)
    for root in roots:
        candidate = root / ns / coll / "plugins" / "modules" / f"{name}.py"
        if candidate.exists():
            return candidate.read_text(encoding="utf-8", errors="replace")
    # ansible.builtin modules ship inside ansible-core (not a galaxy collection
    # root), so fall back to the exact file ansible-doc already resolved.
    filename = ((doc or {}).get("doc") or {}).get("filename")
    if filename and Path(filename).exists():
        return Path(filename).read_text(encoding="utf-8", errors="replace")
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default=str(Path(__file__).resolve().parents[2] / "configs" / "module_sources"))
    parser.add_argument("--collections", nargs="*", default=COLLECTIONS)
    parser.add_argument(
        "--only",
        nargs="*",
        help="Dump only these module short-names within the given collection(s) "
        "(e.g. --collections ansible.builtin --only debug set_fact assert).",
    )
    args = parser.parse_args()

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    roots = collection_roots()
    only = set(args.only) if args.only else None

    total = 0
    missing_source = []
    for collection in args.collections:
        fqcns = list_modules(collection)
        if only:
            fqcns = [f for f in fqcns if f.rsplit(".", 1)[1] in only]
        print(f"{collection}: {len(fqcns)} modules")
        for i in range(0, len(fqcns), CHUNK):
            chunk = fqcns[i : i + CHUNK]
            docs = run_json(["ansible-doc", "-j"] + chunk)
            for fqcn in chunk:
                doc = docs.get(fqcn) or {}
                source = find_source(roots, fqcn, doc)
                if source is None:
                    missing_source.append(fqcn)
                record = {
                    "fqcn": fqcn,
                    "collection": collection,
                    "name": fqcn.rsplit(".", 1)[1],
                    "short_description": (doc.get("doc") or {}).get("short_description", ""),
                    "doc": doc.get("doc") or {},
                    "examples": doc.get("examples") or "",
                    "return": doc.get("return") or {},
                    "source_py": source or "",
                }
                (out_dir / f"{fqcn}.json").write_text(
                    json.dumps(record, indent=1, sort_keys=True, ensure_ascii=False), encoding="utf-8"
                )
                total += 1
    print(f"dumped {total} modules to {out_dir}")
    if missing_source:
        print(f"WARNING: no Python source found for {len(missing_source)}: {missing_source[:10]}...")
    return 0


if __name__ == "__main__":
    sys.exit(main())
