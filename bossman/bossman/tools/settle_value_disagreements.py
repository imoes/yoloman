"""Settle the nine keys where the directive catalog and the template state different value sets — against
the man page, not against a preference.

    python -m bossman.tools.settle_value_disagreements [--write] [--only /etc/redis/redis.conf]

configs/value_set_disagreements.json records where the two catalogs contradict each other for one setting.
The audit that produced it deliberately picked no winner, because neither side is systematically right: the
directive is correct for freeipmi's privilege levels, the template for console-setup's codesets. Deciding
needs a source, and the qualify batch already has one — `_resolve_man` walks the local `man`, then man7.org,
then manpages.debian.org. Same chain, reused rather than reimplemented, so "which man page" cannot have two
answers.

THE RULE, and it is the grounding rule this codebase already applies everywhere else: a candidate value
survives if it appears VERBATIM in the man page, as a whole token. The settled set is the union of both
catalogs filtered that way — union, because a disagreement is usually one side being incomplete
(/etc/redis/redis.conf: the template adds `nothing`, which redis really accepts) rather than one side being
wrong.

AND IT ABSTAINS OUT LOUD. Three ways this refuses to decide, each recorded with the reason:

  * no man page could be fetched — nothing was consulted, so nothing is settled
  * fewer than two values ground — a set of one is not a choice, and an empty one would delete both catalogs'
    answers on the strength of a failed HTTP request
  * some candidate value does not appear in the page. An absent word is NOT an illegal value, and prose
    matching is not strong enough to claim otherwise — measured, `PASSWORD` and `KEY` ground on ordinary
    sentences while `CALLBACK`, a real IPMI privilege level, appears nowhere in ipmiseld(5). So nothing is
    ever deleted on absence; the unconfirmed values are recorded for a stronger source instead. The only two
    deletions are ones the page cannot be wrong about: an empty string is not a value, and a value that is a
    strict prefix of a grounded one is a truncation (`Arm` beside `Armenian`)

Nothing is widened beyond what the two catalogs already claim. This does not go looking for values neither
side knows; it decides between them.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import re

from bossman.services.websearch import SearxngClient
from bossman.tools._jsonio import write_catalog
from bossman.tools._paths import configs_dir
from bossman.tools.qualify_packages import SEARXNG, _resolve_man

CONFIGS = configs_dir(__file__)
DISAGREEMENTS = CONFIGS / "value_set_disagreements.json"
DIRECTIVES = CONFIGS / "config_directives.json"
TEMPLATES = CONFIGS / "config_templates"
RECORD = CONFIGS / "value_set_settlements.json"

#: How long a fetched page must be to count as a man page HERE. Higher than the batch's 800 on purpose: a
#: weak page merely fails to ground anything for the batch, while for this tool it would narrow two catalogs
#: with confidence. Measured: the Debian Manpages navigation stub for ddclient(8) is 1548 characters, and a
#: real section-5 config page runs to tens of thousands.
_MIN_MAN_CHARS = 6000


def grounded(values: list[str], blob: str) -> list[str]:
    """The values that appear verbatim in the source, as whole tokens.

    Same predicate as the enum stage's anti-hallucination gate: a whole-token, case-insensitive match. The
    lookarounds matter — without them `USER` would ground on `ADMINISTRATOR` being absent but `USERNAME`
    being present, and `b` (hostapd's hw_mode) would ground on every word containing a b.
    """
    low = blob.lower()
    out = []
    for value in values:
        if not value:
            continue
        if re.search(rf"(?<![\w-]){re.escape(value.lower())}(?![\w-])", low):
            out.append(value)
    return out


async def settle(rows: list[dict], only: str = "") -> list[dict]:
    searx = SearxngClient(SEARXNG)
    results = []
    for row in rows:
        path, key = row["path"], row["key"]
        if only and only not in (path, f"{path}::{key}"):
            continue
        base = path.rsplit("/", 1)[-1]
        # The template NAME and the file's basename are both offered as man-page candidates, the same pair
        # the batch uses: the page is called sshd_config for the template `openssh_server`.
        man = await _resolve_man(searx, row.get("template") or base, base)
        both = list(dict.fromkeys([*row["directive_values"], *row["template_values"]]))
        if not man:
            results.append({**row, "settled": None,
                            "reason": "no man page could be fetched for this file — nothing was consulted"})
            continue
        # A SUBSTANTIAL page, not merely a successful fetch. _resolve_man accepts anything over 800
        # characters, which is the right bar for the batch (a weak page simply grounds nothing) and the wrong
        # one here, because this tool NARROWS two existing catalogs and a stub would do it confidently.
        # The ddclient stub was 1548 characters; a real section-5 config page is tens of thousands.
        if len(man) < _MIN_MAN_CHARS:
            results.append({**row, "settled": None,
                            "reason": f"the fetched page is only {len(man)} characters — a navigation stub "
                                      f"rather than a man page, and narrowing a catalog needs a real one"})
            continue
        keep = grounded(both, man)
        if len(keep) < 2:
            results.append({**row, "settled": None, "grounded": keep,
                            "reason": f"only {len(keep)} of {len(both)} candidate values appear in the man "
                                      f"page; a set of one is not a choice, and an empty one would delete "
                                      f"both catalogs' answers on the strength of one fetch"})
            continue
        # THE SETTLED SET MUST CONTAIN AT LEAST ONE CATALOG'S SET ENTIRELY. Anything less is not a decision
        # between the two, it is a third answer invented by whatever page was fetched — and that is not a
        # hypothetical. Measured on /etc/ddclient.conf `protocol`: the fetch returned a 1548-character
        # DEBIAN MANPAGES NAVIGATION STUB, `easydns` appeared in its chrome and `dyndns2` did not, and the
        # first version of this rule settled a 21-value set down to ['easydns', 'dyndns'] — deleting
        # cloudflare and eighteen other protocols ddclient really supports. A confident narrowing from a
        # wrong source is the worst thing this tool could produce.
        # SETTLE BY UNION. NEVER DELETE ON A MISSING WORD.
        #
        # A value absent from a fetched page is not an illegal value, and word-matching prose is not strong
        # enough to decide that it is. Measured on the two freeipmi keys: `PASSWORD` and `KEY` "ground" on
        # ordinary English sentences, while `CALLBACK` — a real IPMI privilege level — does not appear in
        # ipmiseld's page at all. A rule that trusted absence deleted the real value and kept the prose.
        #
        # TWO DELETIONS ARE SAFE, because they are verifiable without the page being right:
        #   an EMPTY string is not a value at all
        #   a value that is a strict PREFIX of a grounded value is a TRUNCATION — `Arm` beside `Armenian`
        # Anything else unconfirmed means abstain, with the unconfirmed values recorded so a stronger source
        # (or a person) has the list.
        kept = set(keep)
        unconfirmed = [v for v in both if v not in kept]
        truncations = [v for v in unconfirmed
                       if not v or any(g != v and g.startswith(v) for g in keep)]
        remaining = [v for v in unconfirmed if v not in truncations]
        if remaining:
            results.append({**row, "settled": None, "grounded": keep, "unconfirmed": remaining,
                            "reason": "{} of {} values do not appear in the man page ({}) — and an absent "
                                      "word is not an illegal value, so nothing is deleted on it"
                                      .format(len(remaining), len(both), ", ".join(remaining[:6]))})
            continue
        settled = [v for v in both if v in kept]
        results.append({**row, "settled": settled, "dropped": sorted(truncations),
                        "reason": "the man page confirms every value; the union of both catalogs is the "
                                  "answer" + (" (empty strings and truncated duplicates dropped)"
                                              if truncations else "")})
    return results


def apply(settlements: list[dict]) -> int:
    """Write the settled sets into BOTH catalogs, so the two stop disagreeing."""
    directives = json.loads(DIRECTIVES.read_text())
    changed = 0
    by_template: dict[str, dict] = {}
    for row in settlements:
        if not row.get("settled"):
            continue
        path, key, values = row["path"], row["key"], row["settled"]
        spec = (directives.get(path) or {}).get(key)
        if isinstance(spec, dict):
            spec["values"] = values
            spec.pop("enum", None)
            changed += 1
        tname = row.get("template")
        if tname:
            by_template.setdefault(tname, {})[key] = values
    if changed:
        write_catalog(DIRECTIVES, directives, sort=True)
    for tname, keys in by_template.items():
        f = TEMPLATES / tname / "schema.json"
        try:
            schema = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        props = schema.get("properties", schema) if isinstance(schema, dict) else {}
        if not isinstance(props, dict):
            continue
        touched = False
        for key, values in keys.items():
            if isinstance(props.get(key), dict):
                props[key]["enum"] = values
                touched = True
        if touched:
            f.write_text(json.dumps(schema, indent=2) + "\n")
    return changed


async def main_async() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--only", default="", help="one path, or path::key")
    args = ap.parse_args()

    rows = json.loads(DISAGREEMENTS.read_text()).get("disagreements") or []
    settlements = await settle(rows, args.only)
    settled = [s for s in settlements if s.get("settled")]
    print(f"{len(settlements)} disagreement(s) examined, {len(settled)} settled\n")
    for s in settlements:
        mark = "SETTLED" if s.get("settled") else "abstain"
        print(f"{mark}  {s['path']} :: {s['key']}")
        if s.get("settled"):
            print(f"          -> {s['settled']}")
            if s.get("dropped"):
                print(f"          dropped (not in the man page): {s['dropped']}")
        else:
            print(f"          {s['reason']}")
    if args.write:
        n = apply(settlements)
        write_catalog(RECORD, {"settlements": settlements}, sort=False)
        print(f"\nwrote {n} directive key(s) and their templates, plus {RECORD.name}")
    else:
        print("\n(no --write — catalogs untouched)")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main_async()))
