#!/usr/bin/env python3
"""Stage, for the agent package, the config templates a surface on the agent can actually reach.

    scripts/stage-agent-templates.py [--out deploy-artifacts/agent-templates] [--check]

WHY THIS EXISTS. The package shipped all 5474 template directories in configs/config_templates. Measured:
36 MB of content in ~124 MB of filesystem blocks and ~22 000 files, on every managed host. The backlog
called for pushing them on demand, "like the checks". Measuring first said something better:

  1. THE BOSSMAN-MANAGED WRITE PATH NEEDS NONE OF THEM. A template resource carries its Jinja2 source
     INLINE — internal/state/state.go:43 (`Resource.Template`) and :145, which hands the body straight to
     the template_render module. Bossman renders from the document it sent; the host's own tree is never
     consulted. So the tree exists for exactly one consumer: the STANDALONE management console, on a host
     with no Bossman.
  2. THAT CONSOLE CAN ONLY REACH A TEMPLATE THAT SOMETHING NAMES. It opens a template either because a path
     in config_template_index.json binds it (the Configuration tab) or because a package_catalog.json entry
     references it (the roles wizard). Measured: 1029 index-bound + 472 catalog-referenced = 1042 distinct,
     7.1 MB. The remaining 4432 directories are named by nothing — there is no request that can return them.

So the fix is not a delivery mechanism, it is not shipping what cannot be asked for. An on-demand push would
have been a SECOND way to get a template onto a host, with no caller for it: the managed path already carries
the body, and the standalone path cannot reach these names. Two ways to the same result is a logic error.

WHAT IS ASSERTED, not assumed. The index and the templates must come from ONE snapshot, or the console would
bind a path to a template the package does not carry — a reachable path with no body, which is worse than a
missing one because the editor would offer it and then fail. So closure is CHECKED here and the build stops
if it does not hold: every name the index or the catalog references must be present.

AND THE ABSENCE IS EXPLAINABLE. configs/config_templates_manifest.json records how many were shipped, how
many were withheld and by which criterion; GET /api/v1/config-templates quotes it. An operator comparing the
agent's list against Bossman's finds the difference stated rather than having to discover it.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONFIGS = ROOT / "configs"
TEMPLATES = CONFIGS / "config_templates"
MANIFEST = CONFIGS / "config_templates_manifest.json"

#: Stated in the manifest and quoted by the agent's own endpoint, so the reason travels with the package
#: rather than living only in this file.
CRITERION = ("a template is shipped when config_template_index.json binds a path to it or "
             "package_catalog.json references it — those are the only two ways a request can name one")


def referenced_templates() -> tuple[set[str], set[str]]:
    """(index-bound, catalog-referenced) template names.

    Every family is walked, not just base: the redhat block differs from base on 8 paths, and a template
    reachable only on RHEL is still reachable. A null family entry means "identical to base" (that is the
    recorded convention, kept so there is one answer to maintain rather than three copies).
    """
    index = json.loads((CONFIGS / "config_template_index.json").read_text())
    blocks = [index.get("base") or {}]
    blocks += [b for b in (index.get("families") or {}).values() if b]
    bound: set[str] = set()
    for block in blocks:
        for entry in (block.get("paths") or {}).values():
            name = (entry or {}).get("template")
            if name:
                bound.add(name)

    # The catalog is walked RECURSIVELY for any "template" key: an entry may carry one at the top level
    # (what promote_index_to_catalog writes) and a curated one may carry a per-family override. Looking only
    # where today's writer puts it would silently drop tomorrow's.
    catalog = json.loads((CONFIGS / "package_catalog.json").read_text())
    referenced: set[str] = set()

    def walk(node: object) -> None:
        if isinstance(node, dict):
            name = node.get("template")
            if isinstance(name, str) and name:
                referenced.add(name)
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    walk(catalog)
    return bound, referenced


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="deploy-artifacts/agent-templates",
                    help="staging directory the package's config_templates is built from")
    ap.add_argument("--check", action="store_true",
                    help="report and verify closure without staging anything")
    args = ap.parse_args()

    on_disk = {d.name for d in TEMPLATES.iterdir() if d.is_dir()}
    bound, referenced = referenced_templates()
    wanted = bound | referenced

    # CLOSURE. A referenced name with no directory would give the console a path it offers and cannot serve.
    # Reported in full rather than counted: a build that fails needs to say on what.
    missing = sorted(wanted - on_disk)
    if missing:
        print("the index or the catalog references {} template(s) that are not on disk:".format(len(missing)),
              file=sys.stderr)
        for name in missing[:20]:
            print("   " + name, file=sys.stderr)
        if len(missing) > 20:
            print("   … and {} more".format(len(missing) - 20), file=sys.stderr)
        return 1

    ship = sorted(wanted & on_disk)
    withheld = sorted(on_disk - wanted)
    print(">> {} template dirs on disk".format(len(on_disk)))
    print(">> {} index-bound, {} catalog-referenced, {} distinct reachable".format(
        len(bound & on_disk), len(referenced & on_disk), len(ship)))
    print(">> {} withheld: nothing names them".format(len(withheld)))

    if args.check:
        return 0

    out = ROOT / args.out
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    bytes_shipped = 0
    for name in ship:
        shutil.copytree(TEMPLATES / name, out / name)
        for base, _, files in os.walk(out / name):
            bytes_shipped += sum(os.path.getsize(os.path.join(base, f)) for f in files)

    MANIFEST.write_text(json.dumps({
        "shipped": len(ship),
        "withheld": len(withheld),
        "on_disk": len(on_disk),
        "index_bound": len(bound & on_disk),
        "catalog_referenced": len(referenced & on_disk),
        "criterion": CRITERION,
    }, indent=1, sort_keys=True) + "\n")

    # The withheld NAMES go to the build directory, not into the package: 4432 names are of interest when
    # asking why a template is absent from a build, and of no interest to a host that can never name one.
    (out.parent / "agent-templates-withheld.json").write_text(
        json.dumps({"criterion": CRITERION, "withheld": withheld}, indent=1) + "\n")

    print(">> staged {} dirs, {:.1f} MB → {}".format(len(ship), bytes_shipped / 1e6, out))
    print(">> {} + deploy-artifacts/agent-templates-withheld.json".format(MANIFEST.name))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
