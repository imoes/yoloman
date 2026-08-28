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
from bossman.tools.qualify_packages import SEARXNG, _deb_config, _resolve_man, deb_doc_samples

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


#: `option = [a|b|c]` — an option's own definition line enumerating its whole range. Also `<a|b|c>` and
#: `{a|b|c}`, which the same pages use interchangeably. Two or more alternatives only: a single `[value]` is
#: a placeholder, not a set.
_CLOSED_ENUM = r"(?<![\w.-]){key}\s*=\s*[\[<{{]\s*([^\]>}}\n]*\|[^\]>}}\n]*?)\s*[\]>}}]"


def closed_enum(key: str, blob: str) -> list[str] | None:
    """The values a source states as the OPTION'S WHOLE RANGE, or None if it states no such thing.

    THIS IS THE ONE THING THAT MAY DELETE. Everywhere else this tool refuses to narrow on a missing word,
    for the good reason recorded above: an absent word is not an illegal value. But a page that writes

        security_layer = [tls|rdp|negotiate]

    in the option's own definition is not being silent about `x509` — it is saying the range is those three.
    That is positive evidence about the SET, not absence of evidence about a member, and it is the only shape
    that distinguishes the two. Measured on the four remaining disagreements: exactly one of them has it, and
    it is the one where a union would have propagated a wrong value (`x509`, which xrdp does not accept) into
    the catalog that had it right.

    Deliberately strict, because a wrong match here deletes: at least two alternatives, separated by `|`,
    each a bare word, on the key's own `=` line.
    """
    match = re.search(_CLOSED_ENUM.format(key=re.escape(key)), blob)
    if not match:
        return None
    values = [v.strip() for v in match.group(1).split("|")]
    if len(values) < 2 or not all(v and re.fullmatch(r"[\w.:+-]+", v) for v in values):
        return None
    return values


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


def _package_candidates(path: str) -> list[str]:
    """Package names to try for a path, registry first and then derived from the path itself.

    THE REGISTRY OFTEN CANNOT ANSWER. Measured on the four unsettled disagreements: /etc/ddclient.conf and
    /etc/xdg/swaync/config.json carry `packages: []`, and /etc/xrdp/xrdp.ini carries `["xrdp.ini"]` — a
    FILENAME, which is the 213-entry class audit_package_claims.py recorded. So a fallback is derived from the
    path: the directory under /etc, and the basename without its extension. A wrong guess costs one failed
    `apt-get download` and grounds nothing; a missing guess costs the whole witness.
    """
    codecs = json.loads((CONFIGS / "config_codecs.json").read_text())
    named = [p for p in ((codecs.get(path) or {}).get("packages") or []) if isinstance(p, str)]
    # A name containing a dot or a slash is a file, not a package (Debian Policy 5.6.1 allows neither).
    named = [p for p in named if p and "/" not in p and "." not in p]
    parts = [seg for seg in path.strip("/").split("/") if seg not in ("etc", "xdg")]
    derived = []
    if len(parts) > 1:
        derived.append(parts[0])                     # /etc/xrdp/xrdp.ini  -> xrdp
    if parts:
        derived.append(parts[-1].split(".")[0])      # /etc/ddclient.conf  -> ddclient
    seen: set[str] = set()
    out = []
    for cand in [*named, *derived]:
        if cand and cand not in seen:
            seen.add(cand)
            out.append(cand)
    return out[:4]


async def _doc_samples(path: str) -> str:
    """The commented sample configs the package ships under /usr/share/doc. Blocking, so off the loop."""
    for pkg in _package_candidates(path):
        text = await asyncio.to_thread(deb_doc_samples, pkg)
        if text and len(text) > 400:
            return text
    return ""


async def _shipped_config(path: str, base: str) -> str:
    """The config file the package ships, or "". Blocking (apt/dpkg), so off the event loop."""
    for pkg in _package_candidates(path):
        text, _ships, _real = await asyncio.to_thread(_deb_config, pkg, base, pkg, path)
        if text and len(text) > 200:
            return text
    return ""


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
        # `man` on the ROW when the page's name is derivable from nothing: swaync(5) documents
        # /etc/xdg/swaync/config.json, and neither the template name (sway-notification-center) nor the
        # basename (config.json) can be turned into it by any rule. Measured: without it the fetch grounded
        # 0 of 4 values and the tool abstained on a set every one of whose members the real page contains.
        # A recorded fact, not a guess — and it is per row, so it cannot affect anything else.
        man = await _resolve_man(searx, row.get("man") or row.get("template") or base, base)
        both = list(dict.fromkeys([*row["directive_values"], *row["template_values"]]))
        # BOTH WITNESSES, NOT ONE. The config the package ships is where a project usually writes its value
        # set — redis.conf lists "debug / verbose / notice / warning" in a comment beside the setting — and
        # its man page can be real, long, and silent on that particular key. Preferring the man page BECAUSE
        # it loaded was measured to abstain on exactly that: redis's 43 kB page does not contain `verbose` or
        # `notice`, while its own config file does. A value confirmed by EITHER source is confirmed; taking
        # the union can only enlarge the confirmed set, never delete from it.
        parts, names = [], []
        if man and len(man) >= _MIN_MAN_CHARS:
            parts.append(man)
            names.append("the man page")
        shipped = await _shipped_config(path, base)
        if shipped:
            parts.append(shipped)
            names.append("the config file the package ships")
        # …AND THE PACKAGE'S OWN DOCUMENTED SAMPLE, which is a different file and usually the better witness:
        # /etc/hostapd/hostapd.conf as shipped says almost nothing, while
        # /usr/share/doc/hostapd/examples/hostapd.conf is 128 kB and mentions hw_mode ten times. Nothing had
        # been looking there, which is part of why "both sources are silent" happened as often as it did.
        docs = await _doc_samples(path)
        if docs:
            parts.append(docs)
            names.append("the sample config the package documents")
        source = "\n".join(parts)
        origin = " and ".join(names)
        if not source:
            results.append({**row, "settled": None,
                            "reason": "no man page and no shipped config could be fetched for this file — "
                                      "nothing was consulted"})
            continue
        # BEFORE the union rule: a source that enumerates the option's whole range has already answered,
        # and it can answer in the one direction the union cannot — by ruling a value out.
        enumerated = closed_enum(key, source)
        if enumerated and any(v in both for v in enumerated):
            excess = [v for v in both if v not in enumerated]
            results.append({**row, "settled": enumerated, "dropped": sorted(excess), "source": origin,
                            "closed_enum": True,
                            "reason": f"{origin} enumerates the whole range in the option's own definition "
                                      f"({key} = [{'|'.join(enumerated)}]) — a statement about the SET, not "
                                      f"silence about a member, so it settles in both directions"
                                      + (f"; dropped {', '.join(excess)}" if excess else "")})
            continue

        keep = grounded(both, source)
        if len(keep) < 2:
            results.append({**row, "settled": None, "grounded": keep, "source": origin,
                            "reason": f"only {len(keep)} of {len(both)} candidate values appear in {origin}; "
                                      f"a set of one is not a choice, and an empty one would delete both "
                                      f"catalogs' answers on the strength of one fetch"})
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
                            "source": origin,
                            "reason": "{} of {} values do not appear in {} ({}) — and an absent word is not "
                                      "an illegal value, so nothing is deleted on it"
                                      .format(len(remaining), len(both), origin, ", ".join(remaining[:6]))})
            continue
        settled = [v for v in both if v in kept]
        results.append({**row, "settled": settled, "dropped": sorted(truncations), "source": origin,
                        "reason": f"{origin} confirms every value; the union of both catalogs is the "
                                  f"answer" + (" (empty strings and truncated duplicates dropped)"
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
