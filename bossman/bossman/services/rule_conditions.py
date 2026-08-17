"""Checkmk rule conditions — the six condition fields, ported.

A Checkmk rule condition is exactly six fields (RuleConditionsSpec,
cmk/utils/rulesets/ruleset_matcher.py:106). All six are adopted here, in Checkmk's own
JSON-representable shapes, so a condition written against Checkmk's REST API stays readable
here (Batch 7's API-compatibility goal):

    host_name              ["h1", {"$regex": "^web"}]  or  {"$nor": [...]}
    host_folder            an OU path — the rule applies from there downwards
    host_tags              {"env": "prod"} | {"env": {"$or": ["prod","stage"]}}
                                          | {"env": {"$ne": "test"}} | {"$nor": [...]}
    host_groups            ["webservers", "prod"]  or  {"$nor": ["staging"]}   (Bossman)
    host_label_groups      [["and", [["and", "k:v"], ["not", "k2:v2"]]], ["or", [...]]]
    service_label_groups   same grammar, on the service's labels
    service_description    same shape as host_name, matched against the service name

WHAT IS DELIBERATELY *NOT* TAKEN OVER: Checkmk's ordered rulesets with position-derived
precedence. Our precedence stays GPO (services/gpo.py) — decided, because rule ordering is
exactly the Checkmk complexity the simpler UI exists to avoid. Conditions decide WHETHER a
rule applies; GPO decides WHICH of the applying ones wins. The two are orthogonal, which is
why adopting the conditions costs nothing on the precedence side.

Empty/absent conditions match everything, so every existing rule keeps behaving exactly as
before this module existed.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from functools import lru_cache
from typing import Any

# A label is one "key:value" string in a group — Checkmk's BaseLabel.from_str form.
_LABEL_SEP = ":"


@dataclass
class MatchContext:
    """Everything a condition can be evaluated against.

    `ou_paths` is the host's OU ancestry (root → leaf) so `host_folder` can mean "at or
    below this folder", the way Checkmk's host_folder does.
    """

    host_name: str = ""
    ou_paths: list[str] = field(default_factory=list)
    host_tags: dict[str, str] = field(default_factory=dict)
    host_labels: dict[str, str] = field(default_factory=dict)
    service_name: str | None = None
    service_labels: dict[str, str] = field(default_factory=dict)
    # Bossman extensions to Checkmk's six fields (same match grammar as host_tags):
    # `host_facts` = the host's Ansible facts, flattened to dotted keys
    # (os.family, …); `host_vars` = its resolved desired-state variables
    # (services/scope_vars). Both are flat {key: value} maps.
    host_facts: dict[str, str] = field(default_factory=dict)
    host_vars: dict[str, str] = field(default_factory=dict)
    # `host_groups` = the NAMES of every host group this host belongs to, including the ones it
    # inherits through group paths ("Europe" governs "Europe/Latvia"). It exists so a rule can be
    # scoped to an OU *and* narrowed to a group — an AND that the scope alone cannot express, since
    # a rule's scope is exactly one of OU / group / site.
    host_groups: list[str] = field(default_factory=list)


def flatten_facts(facts: Any, prefix: str = "", out: dict[str, str] | None = None) -> dict[str, str]:
    """Flatten a nested facts dict to dotted scalar keys (os.family → "Debian")
    for the host_facts match dimension. Lists and the bulky installed_packages
    entry are skipped — conditions match single scalar facts, not collections."""
    out = {} if out is None else out
    if not isinstance(facts, dict):
        return out
    for k, v in facts.items():
        if k == "installed_packages":
            continue
        key = f"{prefix}.{k}" if prefix else str(k)
        if isinstance(v, dict):
            flatten_facts(v, key, out)
        elif isinstance(v, (str, int, float, bool)) or v is None:
            out[key] = "" if v is None else str(v)
        # lists / other → skipped
    return out


def matches(conditions: dict[str, Any] | None, ctx: MatchContext) -> bool:
    """Does this rule's condition apply to `ctx`?

    All six fields are ANDed with each other — a rule applies when every condition it
    states is satisfied. Within tags and labels, and/or/not apply as Checkmk defines them.
    """
    if not conditions:
        return True  # no condition = applies everywhere

    if (host_name := conditions.get("host_name")) is not None:
        if not _matches_name(host_name, ctx.host_name):
            return False

    if folder := conditions.get("host_folder"):
        # "at or below" — the folder itself counts, like Checkmk's rule_path.
        if not any(p == folder or p.startswith(folder.rstrip("/") + "/") for p in ctx.ou_paths):
            return False

    for group_id, condition in (conditions.get("host_tags") or {}).items():
        if not matches_tag_condition(str(group_id), condition, ctx.host_tags):
            return False

    # Bossman extensions — same is/$ne/$or/$nor grammar as host_tags, evaluated
    # against the host's Ansible facts and its resolved desired-state variables.
    for key, condition in (conditions.get("host_facts") or {}).items():
        if not matches_tag_condition(str(key), condition, ctx.host_facts):
            return False
    for key, condition in (conditions.get("host_vars") or {}).items():
        if not matches_tag_condition(str(key), condition, ctx.host_vars):
            return False

    # Group membership as a CONDITION, which is what makes "OU and group" expressible: the rule is
    # scoped to the OU (so it inherits downwards and keeps GPO precedence) and this narrows it to the
    # members of a group. Doing it as a second scope instead would have meant deciding which of two
    # scopes wins, and that is the ordered-ruleset complexity this design exists to avoid.
    #
    # Same grammar as host_name, deliberately: a bare list means ANY of these groups (a picker's
    # natural reading), and {"$nor": [...]} means none of them. AND across several groups is
    # expressible by naming a group that is itself the intersection — inventing a second, silent
    # meaning for a list would be worse than not offering it.
    if (want_groups := conditions.get("host_groups")) is not None:
        if not _matches_any_name(want_groups, ctx.host_groups):
            return False

    if groups := conditions.get("host_label_groups"):
        if not matches_labels(ctx.host_labels, groups):
            return False

    # Service-level conditions are skipped when evaluating a host-level rule: a rule that
    # names a service cannot be judged before a service is in hand, and silently treating
    # that as "no match" would drop the rule from the host entirely.
    if ctx.service_name is not None:
        if (desc := conditions.get("service_description")) is not None:
            if not _matches_name(desc, ctx.service_name):
                return False
        if groups := conditions.get("service_label_groups"):
            if not matches_labels(ctx.service_labels, groups):
                return False

    return True


def matches_labels(object_labels: dict[str, str], required_label_groups: Any) -> bool:
    """Port of Checkmk's matches_labels (ruleset_matcher.py:860).

    The grammar is two levels of and/or/not: labels within a group, then groups against
    each other. `not` means "and not" — see _and_or_not.

    Both accumulators start True, which is why Checkmk notes that the first operator in a
    group is always "and" or "not": a leading "or" would short-circuit to True. Kept faithful
    rather than "fixed", so a condition behaves the same here as it does there.
    """
    overall = True
    for entry in required_label_groups or []:
        group_operator, label_group = _pair(entry)
        group_match = True
        for member in label_group or []:
            label_operator, label = _pair(member)
            if not label:
                continue
            if not object_labels:
                # An object with no labels matches a group only if the group demands none.
                if label_operator == "and":
                    group_match = False
                    break
                continue
            name, _, value = str(label).partition(_LABEL_SEP)
            label_match = object_labels.get(name) == value
            group_match = _and_or_not(group_match, label_match, label_operator)
        overall = _and_or_not(overall, group_match, group_operator)
    return overall


def matches_tag_condition(group_id: str, condition: Any, host_tags: dict[str, str]) -> bool:
    """Port of Checkmk's matches_tag_condition (ruleset_matcher.py:900+).

    A bare value means equality; the dict forms are $ne (not this), $or (any of) and $nor
    (none of). Our tags are a flat {group: value} mapping, where Checkmk carries a set of
    (group, value) pairs — the same information for single-valued tag groups, which is all
    Agent.tags can express.
    """
    actual = host_tags.get(group_id)
    if isinstance(condition, dict):
        if "$ne" in condition:
            return actual != condition["$ne"]
        if "$or" in condition:
            return actual in (condition.get("$or") or [])
        if "$nor" in condition:
            return actual not in (condition.get("$nor") or [])
        return False  # an unknown operator must not silently match everything
    return actual == condition


def _and_or_not(accumulated: bool, new: bool, operator: Any) -> bool:
    """Checkmk's _and_or_not_group_match — note that "not" is AND NOT, not a plain negation."""
    if operator == "or":
        return accumulated or new
    if operator == "not":
        return accumulated and not new
    return accumulated and new  # "and", and the default for anything unexpected


def _matches_name(condition: Any, text: str) -> bool:
    """host_name / service_description: a list of exact names and/or {"$regex": …},
    optionally wrapped in {"$nor": [...]} to negate the whole list.

    Checkmk combines the list into ONE regex for speed and anchors with `match` (start of
    string, not full). Both details are kept: "^web" and "web" behave as they do there.
    """
    negate, patterns = _parse_negated(condition)
    if not patterns:
        return True  # an empty list matches everything, as in Checkmk
    hit = _compiled(tuple(patterns)).match(text or "") is not None
    return not hit if negate else hit


def _matches_any_name(condition: Any, values: list[str]) -> bool:
    """host_groups: does ANY of the host's group names satisfy the condition?

    The sibling of _matches_name, and it has to be a sibling rather than the same function: that one
    asks about ONE string (the host's name), this one about a SET (every group the host is in). The
    negation therefore means something stricter here — {"$nor": ["staging"]} must hold for ALL the
    host's groups, i.e. it is in none of them. Reusing _matches_name per value and OR-ing would have
    made "$nor" mean "at least one group is not staging", which is true for almost every host and
    would have quietly matched the opposite of what was written.
    """
    negate, patterns = _parse_negated(condition)
    if not patterns:
        return True  # an empty list matches everything, as with host_name
    rx = _compiled(tuple(patterns))
    hit = any(rx.match(v or "") is not None for v in values)
    return not hit if negate else hit


def _parse_negated(condition: Any) -> tuple[bool, list[str]]:
    if isinstance(condition, dict) and "$nor" in condition:
        return True, _pattern_parts(condition.get("$nor") or [])
    return False, _pattern_parts(condition or [])


def _pattern_parts(entries: Any) -> list[str]:
    out: list[str] = []
    for e in entries if isinstance(entries, (list, tuple)) else [entries]:
        if isinstance(e, dict) and "$regex" in e:
            out.append(str(e["$regex"]))
        elif e is not None:
            # A plain name is an exact match, so it is escaped and anchored — otherwise
            # host "web" would match "web-staging" through the shared regex.
            out.append(re.escape(str(e)) + "$")
    return out


@lru_cache(maxsize=2048)
def _compiled(patterns: tuple[str, ...]) -> re.Pattern[str]:
    """One combined regex per pattern list, cached — the matcher runs per host per poll."""
    return re.compile("|".join(f"(?:{p})" for p in patterns))


def _pair(entry: Any) -> tuple[Any, Any]:
    """A ("operator", value) pair — a JSON round trip turns Checkmk's tuples into lists."""
    if isinstance(entry, (list, tuple)) and len(entry) == 2:
        return entry[0], entry[1]
    return "and", entry
