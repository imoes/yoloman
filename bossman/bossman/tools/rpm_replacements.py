"""Which RedHat packages does the repository REPLACE — so that installing them installs another package?

    .venv-host/bin/python -m bossman.tools.rpm_replacements [--write]

WHY. `dnf install hirte` installs bluechi-controller 1.3.0, whose `Obsoletes: hirte < 0.6.0` covers hirte 0.4.0 —
so the file measured in hirte's own RPM (/etc/hirte/hirte.conf) is on no host, and the pod run failed writing it
(measured 2026-10-15). A route for such a package names a file nobody gets; the package that is really installed has
its own route.

HOW. One repoquery over the whole repository in the long-lived fetch container (tools/rpm_source): every package's
latest EVR and its Obsoletes. A universe package is REPLACED when another package obsoletes it and the obsoletes
constraint covers its latest version (rpm's own labelCompare, run in the container). Result:
configs/package_replacements.json {"redhat": {package: {by, evr, obsoletes}}} — read by package_e2e_worklist, which
routes such a package `replaced`, naming the replacement.
"""

from __future__ import annotations

import argparse
import json
import subprocess

from bossman.tools import qualify_packages as Q
from bossman.tools.rpm_source import CONTAINER, ensure_container

OUT = Q._CONFIGS / "package_replacements.json"

# Runs INSIDE the container (python3 + rpm bindings are part of AlmaLinux); reads the universe names on stdin.
_PROBE = r'''
import json, re, subprocess, sys, rpm
names = set(json.load(sys.stdin))
q = lambda fmt: subprocess.run(["dnf", "-q", "repoquery", "--latest-limit", "1", "--qf", fmt, "--all"],
                               capture_output=True, text=True, check=True).stdout
evr = dict(l.split("\t", 1) for l in q("%{name}\t%{evr}\n").splitlines() if "\t" in l)
def split(v):
    e, rest = v.split(":", 1) if ":" in v else ("0", v)
    ver, _, rel = rest.partition("-")
    return (e, ver, rel or None)
out, cur = {}, None
for line in q("%{name}\t%{obsoletes}\n").splitlines():   # several obsoletes: continuation lines without a tab
    if "\t" in line:
        cur, line = line.split("\t", 1)
    m = re.match(r"(\S+)(?:\s*(<=|<|=|>=|>)\s*(\S+))?", line.strip())
    if not m or cur is None:
        continue
    name, op, ver = m.groups()
    if name not in names or name == cur or name not in evr:
        continue
    if op:
        c = rpm.labelCompare(split(evr[name]), split(ver))
        if not {"<": c < 0, "<=": c <= 0, "=": c == 0, ">=": c >= 0, ">": c > 0}[op]:
            continue
    out.setdefault(name, {"by": cur, "evr": evr[name], "obsoletes": f"{name} {op or ''} {ver or ''}".strip()})
print(json.dumps(out, sort_keys=True))
'''


def measure(names: list[str]) -> dict:
    ensure_container()
    r = subprocess.run(["docker", "exec", "-i", CONTAINER, "python3", "-c", _PROBE], input=json.dumps(names),
                       capture_output=True, text=True, timeout=1800)
    if r.returncode != 0:
        raise SystemExit(f"repoquery in {CONTAINER} failed: {r.stderr.strip()[-400:]}")
    return json.loads(r.stdout)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()
    universe = Q._load(Q.UNIVERSE, {})
    found = measure(sorted((universe.get("redhat") or {}).keys()))
    for pkg, v in found.items():
        print(f"{pkg}: replaced by {v['by']} (Obsoletes: {v['obsoletes']}; repo has {v['evr']})")
    print(f"{len(found)} of {len(universe.get('redhat') or {})} RedHat packages are replaced in the repository")
    if args.write:
        OUT.write_text(json.dumps({"what": "packages the repository replaces (Obsoletes) — "
                                           "bossman/bossman/tools/rpm_replacements.py", "redhat": found},
                                  indent=1, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
