"""Which package names EXIST on Enterprise Linux — measured in an EL container, not inferred.

    docker run --rm -e http_proxy=$P -e https_proxy=$P \
      -v $PWD/bossman/bossman/tools/record_el_package_names.py:/rec.py:ro -v $PWD/configs:/configs \
      almalinux:9 python3 /rec.py

WHY A SEPARATE RECORD. `curate_catalog` drops a role's `redhat` branch when the branch is identical to Debian
and "not attested", and it asked `package_universe_real.json["redhat"]` — 1902 entries — for the attestation.
That file answers a DIFFERENT question. It was built by `fetch_package_universe.py` from Rocky 9 BaseOS +
AppStream only (no CRB, no EPEL) and then filtered to *configurable-service candidates* by section and
description. So its absence means "not a service candidate in two repos", and it was being read as "does not
exist on RHEL".

Measured consequence: neither `sssd` nor `nginx` is in it. `nginx` survived only because it is in the
builder's hand-written CORE table; `sssd`'s branch was dropped — for a package that IS the canonical RHEL
identity client. That is an incomplete disjunction: "either attested here, or a Debian copy", ignoring "exists
on EL, just not in this filtered listing".

The rule it feeds is right and stays: a fabricated `redhat` branch satisfies `fams.get(family)`, so the
wizard's honest `family_match="fallback"` never runs, and a guess is presented as a curated fact. What was
wrong is the evidence. So this records NAMES ONLY, unfiltered, from the four repos an EL host actually has —
and it does not touch package_universe_real.json, whose `config_paths` a name list would destroy.

Names only, deliberately: attestation needs existence, and anything richer invites the same drift where one
record is asked a question it was not built to answer.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from datetime import datetime, timezone

OUT = "/configs/package_names_el.json"

#: EPEL and CRB are enabled because an EL HOST has them: nearly every self-hosted service an operator would
#: install (fail2ban, haproxy variants, monitoring agents) lives in EPEL, and leaving it out is what made the
#: previous listing read as "RHEL does not ship this".
REPOS = ("baseos", "appstream", "crb", "epel")


def _run(argv: list[str], timeout: int = 900) -> subprocess.CompletedProcess:
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False)


def main() -> int:
    setup = _run(["dnf", "-y", "install", "epel-release", "dnf-plugins-core"])
    if setup.returncode != 0:
        print("could not install epel-release/dnf-plugins-core:\n" + setup.stdout[-2000:], file=sys.stderr)
        return 1
    # crb is called powertools on some rebuilds; try both and do not fail on the one that is absent.
    for name in ("crb", "powertools"):
        _run(["dnf", "config-manager", "--set-enabled", name], timeout=120)

    names: dict[str, list[str]] = {}
    seen_repos: list[str] = []
    for repo in REPOS:
        # --qf keeps this to two fields; a full repoquery dump of four repos is ~100 MB of text for a
        # question that is answered by a name.
        got = _run(["dnf", "repoquery", "--quiet", "--available", "--repo", repo,
                    "--qf", "%{name}\t%{sourcerpm}"])
        lines = [ln for ln in got.stdout.splitlines() if "\t" in ln]
        if got.returncode != 0 or not lines:
            # NAMED, not silent: a repo that could not be queried must not look like a repo with no
            # packages, or the attestation quietly shrinks again.
            print(f"! repo {repo}: no answer ({got.returncode}) — {got.stderr.strip()[:200]}", file=sys.stderr)
            continue
        seen_repos.append(repo)
        for line in lines:
            name, _, _src = line.partition("\t")
            names.setdefault(name.strip(), []).append(repo)
        print(f"  {repo}: {len(lines)} package(s)", flush=True)

    if not seen_repos:
        print("no repo could be queried — writing nothing rather than an empty attestation", file=sys.stderr)
        return 1

    record = {
        "_meta": {
            "measured": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "image": os.environ.get("EL_IMAGE", "almalinux:9"),
            "repos": seen_repos,
            "repos_requested": list(REPOS),
            "question": "does a package with this NAME exist on Enterprise Linux",
            "not": ("this is not package_universe_real.json's redhat half — that one answers 'is this a "
                    "configurable-service candidate', from two repos and a section/description filter, and "
                    "using it as attestation dropped sssd"),
            "count": len(names),
        },
        # name -> the repos that offer it. Which repo matters: a role whose only EL home is EPEL is a
        # different statement to an operator than one in BaseOS.
        "names": {n: sorted(set(r)) for n, r in sorted(names.items())},
    }
    with open(OUT, "w", encoding="utf-8") as fh:
        json.dump(record, fh, indent=2, sort_keys=True, ensure_ascii=False)
        fh.write("\n")
    print(f"\nwrote {OUT}: {len(names)} names from {', '.join(seen_repos)}")
    for probe in ("sssd", "nginx", "httpd", "fail2ban", "ufw", "apt"):
        where = record["names"].get(probe)
        print(f"  {probe:10s} {', '.join(where) if where else 'NOT on EL'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
