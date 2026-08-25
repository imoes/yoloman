"""The invariants a value set must satisfy, in one place — because four passes now write them.

`enums_from_descriptions`, `directive_values`, `mark_open_enums`, `sync_value_sets` and
`settle_value_disagreements` all touch the same two catalogs, and the rules they enforce are the same rules.
Spread across five files they interact, and the interaction is a defect: `mark_open_enums` DEDUPLICATED
`['LOG_DAEMON', 'LOG_DAEMON']` into `['LOG_DAEMON']` — a one-option set, which the pass that removes those had
already run. Two correct rules applied in the wrong order produced the thing both of them forbid.

So the invariants live here and every writer calls `normalise` last:

  1. NO DUPLICATES. A menu with two identical entries cannot be used, and a duplicate means the
     distinguishing part was lost rather than that the author wrote it twice. First occurrence wins; the
     order is what someone chose.
  2. FEWER THAN TWO OPTIONS IS NOT A CHOICE. A one-option dropdown does not look thin — it removes every
     other legal value from reach, and the write path is whole-file. The set goes, the description stays.
  3. …AND RULE 2 IS ASKED AFTER RULE 1, which is the whole reason this file exists.

The label map and the `open` mark travel with the values or die with them: labels for values that no longer
exist are a second answer to a question nobody can ask, and "these are only suggestions" is meaningless once
there is nothing to suggest.
"""

from __future__ import annotations

#: The spelling of the set and of its labels, per catalog. The directive catalog says values/value_labels, a
#: template schema says enum/enum_labels — one translation, made explicit rather than duplicated per caller.
SHAPES = {
    "directive": ("values", "value_labels"),
    "template": ("enum", "enum_labels"),
}
#: The mark is spelled the same in both, because it means the same thing in both.
OPEN_KEY = "enum_open"


def dedupe(values: list) -> list:
    """First occurrence wins, order preserved. `1` and `"1"` are the same OPTION in a menu."""
    seen: set[str] = set()
    out = []
    for value in values:
        key = str(value)
        if key not in seen:
            seen.add(key)
            out.append(value)
    return out


def normalise(spec: dict, shape: str = "template") -> str:
    """Enforce the invariants on one field spec, in place. Returns "" when nothing changed, else the reason.

    Call this LAST in any pass that writes a value set — including one that only reorders or deduplicates,
    because that is how a one-option set was created in the first place.
    """
    set_key, label_key = SHAPES[shape]
    values = spec.get(set_key)
    if not isinstance(values, list):
        return ""
    clean = dedupe(values)
    reason = ""
    if len(clean) != len(values):
        reason = "duplicate value(s) removed"
        spec[set_key] = clean
        values = clean
    if len(values) < 2:
        # The description survives — it is all the operator has left, and it is usually where the real value
        # set is written anyway.
        spec.pop(set_key, None)
        spec.pop(label_key, None)
        spec.pop(OPEN_KEY, None)
        return ("a set of fewer than two options is not a choice — it offered one value and hid every other "
                "legal one" + (f" (after {reason})" if reason else ""))
    labels = spec.get(label_key)
    if isinstance(labels, dict):
        kept = {k: v for k, v in labels.items() if k in {str(x) for x in values}}
        if len(kept) != len(labels):
            # A label for a value that is gone is an answer to a question nobody can ask.
            spec[label_key] = kept
            reason = (reason + "; " if reason else "") + "orphaned label(s) removed"
        if not kept:
            spec.pop(label_key, None)
    return reason
