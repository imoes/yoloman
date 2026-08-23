"""Turn a field's OWN description into its enum — the value set that was already written down.

    python -m bossman.tools.enums_from_descriptions            # report, write nothing
    python -m bossman.tools.enums_from_descriptions --write

WHERE THIS CAME FROM. The enum gap was being attacked with more LLM calls, and the measured yield was +2
fields per 36 templates. Looking at what the un-enumerated fields actually contain says why that is the wrong
tool:

    4g8/log_level        "Logging level: one of 'debug', 'info', 'warn', 'error'"
    ahcpd/log_level      "Verbosity level for server logs. Options: debug, info, notice, warning, error, …"
    alevtd/log_level     "Verbosity of logs: debug, info, warn, or error."
    acmesh/log_level     "Logging verbosity: 0=error, 1=warn, 2=info, 3=debug."

The enumeration is IN THE SCHEMA, next to the field, unparsed. It was recorded when the template was
generated — from the same man-page-grounded pass — and then never turned into an `enum`, so the editor
renders a free-text box beside a description that lists the four legal values. No model, no man page and no
web search is needed to fix that; it is an extraction, and extractions can be tested.

WHY PRECISION OVER RECALL, everywhere below. A wrong dropdown is worse than a text box: the operator cannot
type the value the software actually wants, and a whole-file template render then writes a config the service
refuses. So every gate here is built to REFUSE rather than to guess, and the measured false positives are
named:

    "Additional command-line options to pass to acpid"     — `options` is the noun, not a list
    "Version of DPkg::Tools::Options for adequate"         — the word Options inside a path
    "Only one of dns_manual or dns_hook should be set"     — a sentence about two FIELDS, not two values

and each is caught by a different gate (a list needs separators, items must look like values not prose, and
`one of X or Y` naming other schema fields is rejected).

EVERY DECISION IS RECORDED, accepted and refused alike, in configs/schema_enum_from_desc.json — so "why is
this still a text box" has an answer for the fields this pass declined too.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

from bossman.tools._jsonio import write_catalog
from bossman.tools._paths import configs_dir

CONFIGS = configs_dir(__file__)
TEMPLATES_DIR = CONFIGS / "config_templates"
RECORD = CONFIGS / "schema_enum_from_desc.json"

#: The sentence shapes that introduce a value list. Ordered: the most explicit first, so a description
#: carrying several gets read by the least ambiguous one. Each is anchored to a phrase that means "here come
#: the values" — a bare comma list in prose is not one.
INTRODUCERS = (
    # "values are", "values include", "values can be", or just "values:" — all of them announce the list.
    re.compile(r"\b(?:valid|allowed|possible|supported|accepted|permitted)\s+values?"
               r"(?:\s+(?:are|include|includes|can\s+be|being))?\s*[:=]?\s*(?P<list>.+)", re.I),
    re.compile(r"\bone\s+of\s*[:=]?\s*(?P<list>.+)", re.I),
    re.compile(r"\bchoose\s+from\s*[:=]?\s*(?P<list>.+)", re.I),
    re.compile(r"\boptions?\s*[:=]\s*(?P<list>.+)", re.I),
    re.compile(r"\beither\s+(?P<list>.+)", re.I),
)

#: `0=error, 1=warn, 2=info` — the numeric form, where the VALUE is the number and the word explains it.
#: Handled separately because splitting it on commas like a word list would yield "0=error" as a value.
NUMERIC = re.compile(r"(?<![\w.])(\d+)\s*=\s*([A-Za-z][\w -]{0,20})")

#: A value token: short, no sentence punctuation, not a sentence fragment. Quoted forms are unwrapped first.
VALUE = re.compile(r"^[A-Za-z0-9][\w.+/@-]{0,31}$")

#: Words that mean the "list" is prose rather than values. Every entry here is a word that cannot stand alone
#: as a config value.
#:
#: THE FIRST VERSION ALSO LISTED on, in, at, from, as, by, any and default — and those are exactly the words
#: that ARE values. Measured: it refused openssh_server/address_family (`any`, `inet`, `inet6` — `any` is
#: OpenSSH's own value), postgresql_17/synchronous_commit (`on`, `off`, `local`, …) and 12 more, all correct
#: value sets thrown away for containing a short word. A gate built to be careful was silently deleting the
#: commonest boolean-ish values.
PROSE = {"the", "a", "an", "and", "or", "to", "of", "for", "with", "when", "if", "this", "that", "which",
         "be", "is", "are", "e.g", "eg", "etc", "see", "must", "should", "can", "may", "will",
         "value", "values", "option", "options", "above", "below", "such", "using", "used"}

#: Two or more QUOTED tokens joined by a separator, anywhere in the description. Quotes are the author saying
#: "this is a literal", which is why this needs no introducing phrase to be safe:
#:
#:      "Detection method: 'threshold' or 'stddev'. Must be one of these two values."
#:
#: has no phrase that introduces a list — "one of" appears only in the trailing sentence, whose list is
#: "these two values" — and the real value set is sitting there in quotes. Requiring the quotes is what keeps
#: this from reading every colon in the corpus as an enumeration.
#: The separator between two quoted literals. `,\s*(?:or|and)` is not decoration: a list written
#: "'stdout', 'stderr', or 'file'" has a COMMA AND an "or" before its last item, and a pattern accepting only
#: one of the two stops matching at 'stderr' — silently dropping 'file'. Measured on five fields in one
#: sample (garagemq log.output lost 'file', osmo_sgsn integrity lost 'require', freefilesync on_error lost
#: 'retry'). A TRUNCATED dropdown is worse than no dropdown: it removes a legal value from reach and looks
#: authoritative doing it.
_SEP = r"""(?:\s*,\s*(?:or\s+|and\s+)?|\s*[;|]\s*|\s+(?:or|and)\s+)"""
#: A per-value parenthetical — "'inet' (IPv4 only), or 'inet6'" — sits BETWEEN the value and the separator.
#: Without allowing for it the match ended at 'inet' and dropped inet6: openssh_server/address_family got
#: `any, inet` for a setting whose real set is `any, inet, inet6`, and lvm2/vgmetadatacopies
#: ("'unmanaged' (default), 'all', 'any', or 'none'") was refused outright. Bounded to 40 characters so it
#: stays a gloss and cannot swallow a sentence.
_GLOSS = r"""(?:\s*\([^)]{0,40}\))?"""
QUOTED = re.compile(r"""(?:^|[\s:=(])(['"`])(?P<first>[A-Za-z0-9][\w.+/@-]{0,31})\1"""
                    + r"""(?:""" + _GLOSS + _SEP + r"""(['"`])[A-Za-z0-9][\w.+/@-]{0,31}\3)+""", re.I)
QUOTED_TOKEN = re.compile(r"""(['"`])([A-Za-z0-9][\w.+/@-]{0,31})\1""")

#: The phrases that mark what follows as an EXAMPLE. Looked for in the 40 characters before a quoted list.
#: NO TRAILING \b. "e.g." ends in a period and the next character is usually a comma — between two
#: non-word characters there is no word boundary, so a trailing \b made this pattern unable to match the
#: single most common form of the thing it looks for. Measured: "Device class filter (e.g., 'backlight',
#: 'leds')" was accepted as an enumeration until this was fixed.
#: "Common values: …" is a HEDGE, not an allowed set — it says "some of them". Measured:
#: dhcpd_omapi/omapi_key_algorithm listed two of the four HMAC algorithms that way, and a dropdown built
#: from it would have removed the other two. Same for "typically" and "usually".
EXAMPLE = re.compile(r"\b(?:e\.?g\.?|i\.?e\.?|for\s+example|such\s+as|like|examples?|typically|"
                     r"usually|commonly|common|including|includes?)[\s:,(.]*(?:values?\s*[:=]?\s*)?$", re.I)

#: Separators, in the order they are tried. " or " last: "a, b, or c" must split on commas first.
SPLITTERS = (re.compile(r"\s*[|,;]\s*"), re.compile(r"\s+or\s+", re.I), re.compile(r"\s*/\s*"))


def _unquote(token: str) -> str:
    token = token.strip().strip(".").strip()
    for quote in ("'", '"', "`", "‘", "’", "“", "”"):
        if token.startswith(quote):
            token = token[1:]
        if token.endswith(quote):
            token = token[:-1]
    # "plain (human-readable)" — the parenthetical explains the value, it is not part of it.
    token = re.sub(r"\s*\([^)]*\)\s*$", "", token).strip()
    return token.strip("'\"`").strip()


def _values_from_list(text: str) -> list[str]:
    """Split an introduced list into value tokens, or return [] if it does not look like one."""
    # Stop at the end of the clause: a description continues past its list ("…, error. Defaults to info").
    text = re.split(r"[.;](?:\s|$)", text, maxsplit=1)[0]
    best: list[str] = []
    for splitter in SPLITTERS:
        # "a, b, or c" — the last item arrives as "or c"; the comma split runs first, so strip a leading or.
        parts = [re.sub(r"^\s*or\s+", "", p, flags=re.I) for p in splitter.split(text)]
        tokens = [_unquote(p) for p in parts]
        tokens = [t for t in tokens if t]
        if len(tokens) >= 2 and all(VALUE.match(t) for t in tokens):
            if len(tokens) > len(best):
                best = tokens
    return best


def extract(description: str, field_names: set[str] | None = None) -> tuple[list[str], str]:
    """(values, reason). Empty values with the reason it refused — that is the point, not a side effect."""
    if not description or len(description) > 600:
        return [], "no description" if not description else "description too long to read as a list"

    refusal = ""
    numeric = NUMERIC.findall(description)
    if len(numeric) >= 2:
        # The numbers are the values. The words are what they mean, and they belong in the description that
        # already carries them — putting "1 (error)" in the dropdown would write "1 (error)" into the file.
        return [n for n, _word in numeric], "numeric mapping in the description"

    for pattern in INTRODUCERS:
        match = pattern.search(description)
        if not match:
            continue
        # The hedge gate applies to introduced lists too: "Common values: 'a', 'b'" has both a hedge and an
        # introducer, and the introducer must not win.
        if EXAMPLE.search(description[max(0, match.start() - 40):match.start() + 1]):
            refusal = "the values are introduced as examples or common cases, not as the allowed set"
            continue
        values = _values_from_list(match.group("list"))
        if len(values) < 2:
            # KEEP LOOKING rather than refusing. A description can end with a phrase that introduces
            # nothing — "Detection method: 'threshold' or 'stddev'. Must be one of these two values." — and
            # returning on the first match let that trailing sentence veto the real list before it.
            continue
        ok, why = _plausible(values, field_names)
        if ok:
            return values, "introduced list in the description"
        refusal = why   # remembered, but keep looking: a later introducer may find the real list
    # No introducer produced a usable list. The quoted form needs none — see QUOTED.
    span = QUOTED.search(description)
    if span:
        # AN EXAMPLE IS NOT AN ENUMERATION, and this is the gate that matters most. Measured false positives
        # from the quoted path before it existed:
        #
        #   "Preferred architecture override (e.g., 'amd64', 'arm64'). If omitted, auto-detected."
        #   "Default language, e.g. 'en_US.UTF-8' or 'de_DE'."
        #
        # Both are open sets. Turning them into a dropdown does not merely mislead — it REMOVES i386 and
        # every other legal value from the operator's reach, and the template write path is whole-file.
        lead = description[max(0, span.start() - 40):span.start()].lower()
        if EXAMPLE.search(lead):
            return [], "the quoted values are introduced as an example, not as the allowed set"
        values = [m.group(2) for m in QUOTED_TOKEN.finditer(span.group(0))]
        ok, why = _plausible(values, field_names)
        if ok:
            return values, "two or more quoted literals in the description"
        refusal = refusal or why
    return [], refusal or "no phrase in the description introduces a list of two or more value-shaped tokens"


def _plausible(values: list[str], field_names: set[str] | None) -> tuple[bool, str]:
    """The three gates that separate a value list from a sentence. Each one is a measured false positive."""
    low = [v.lower() for v in values]
    if any(v in PROSE for v in low):
        return False, f"the list reads as prose ({', '.join(v for v in low if v in PROSE)})"
    if field_names and sum(1 for v in low if v in field_names) >= 2:
        # "Only one of dns_manual or dns_hook should be set" — a sentence about two FIELDS.
        return False, "the 'list' names other fields of this schema, not values"
    if len(set(low)) != len(low):
        return False, "the list repeats a value"
    return True, ""


def apply_to(schema: dict) -> tuple[dict, list[dict]]:
    """Fill in enums where the description supports one. Returns (schema, decisions)."""
    props = schema.get("properties", schema) if isinstance(schema, dict) else {}
    if not isinstance(props, dict):
        return schema, []
    names = {k.lower() for k in props}
    decisions: list[dict] = []
    for key, spec in props.items():
        if not isinstance(spec, dict) or spec.get("type") != "string" or spec.get("enum"):
            continue
        values, reason = extract(spec.get("description") or "", names)
        if not values:
            decisions.append({"field": key, "accepted": False, "reason": reason})
            continue
        default = spec.get("default")
        # THE SAME RULE the LLM stage uses: a default outside the set means one of the two is wrong and this
        # pass cannot tell which. Offering the dropdown would change the file's current setting on Apply.
        if default not in (None, "") and str(default) not in values:
            decisions.append({"field": key, "accepted": False, "values": values,
                              "reason": f"the recorded default {default!r} is not in the extracted set"})
            continue
        spec["enum"] = values
        decisions.append({"field": key, "accepted": True, "values": values, "reason": reason})
    return schema, decisions


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--write", action="store_true", help="write the schemas (default: report only)")
    ap.add_argument("--only", default="", help="comma-separated template names")
    ap.add_argument("--show", type=int, default=15, help="how many accepted examples to print")
    args = ap.parse_args()
    only = {s.strip() for s in args.only.split(",") if s.strip()}

    record: dict[str, list[dict]] = {}
    accepted = refused = touched = 0
    shown = 0
    for d in sorted(TEMPLATES_DIR.iterdir()):
        if not d.is_dir() or (only and d.name not in only):
            continue
        try:
            schema = json.loads((d / "schema.json").read_text())
        except (OSError, ValueError):
            continue
        schema, decisions = apply_to(schema)
        if not decisions:
            continue
        got = [x for x in decisions if x["accepted"]]
        accepted += len(got)
        refused += len(decisions) - len(got)
        record[d.name] = decisions
        if got:
            touched += 1
            if args.write:
                (d / "schema.json").write_text(json.dumps(schema, indent=2) + "\n")
            for x in got[: max(0, args.show - shown)]:
                print(f"  {d.name}/{x['field']}: {x['values']}")
                shown += 1

    print(f"\n{accepted} enum(s) from descriptions across {touched} template(s); {refused} field(s) refused")
    if args.write:
        write_catalog(RECORD, record, sort=True)
        print(f"wrote {RECORD}")
    else:
        print("(no --write — schemas untouched)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
