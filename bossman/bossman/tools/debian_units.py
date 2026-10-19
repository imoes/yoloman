"""Which systemd units each Debian package ships — read from the archive's Contents index, written as data.

    .venv-host/bin/python -m bossman.tools.debian_units        # → configs/debian_package_units.json

The catalog needs it to name the unit a role restarts. Roles the classify step promoted from tasksel/comps carried an
empty Debian `service`, so the wizard wrote redis.conf and never restarted redis — and the e2e, which has no unit to
look at, counted the role compliant on the file alone (measured 2026-10-11: 44 roles/features, 30 of them with a unit
named exactly after the package or the role). One reading of the archive, kept as data, so curation stays offline and
the evidence is reviewable: {package: [unit, …]} for every package that ships a non-template `.service`.
"""

from __future__ import annotations

import gzip
import json
from collections import defaultdict

from bossman.tools._jsonio import write_catalog
from bossman.tools._paths import configs_dir
from bossman.tools.package_e2e_worklist import CONTENTS_DIR

OUT = configs_dir(__file__) / "debian_package_units.json"
PREFIXES = ("usr/lib/systemd/system/", "lib/systemd/system/")


def read_units() -> dict[str, list[str]]:
    units: dict[str, set[str]] = defaultdict(set)
    for path in sorted(CONTENTS_DIR.glob("Contents-*.gz")):
        with gzip.open(path, "rt", errors="replace") as fh:
            for line in fh:
                if not line.startswith(PREFIXES):
                    continue
                file, _, pkgs = line.rstrip("\n").rpartition(" ")
                unit = file.strip().rsplit("/", 1)[-1]
                if not unit.endswith(".service") or "@" in unit:
                    continue
                for pkg in pkgs.split(","):
                    units[pkg.rsplit("/", 1)[-1]].add(unit.removesuffix(".service"))
    return {pkg: sorted(u) for pkg, u in sorted(units.items())}


def main() -> int:
    units = read_units()
    if not units:
        print(f"no Contents index under {CONTENTS_DIR} — run package_e2e_worklist --refresh-debian-paths first")
        return 1
    write_catalog(OUT, units, sort=True)
    print(f"{len(units)} packages ship a systemd unit → {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
