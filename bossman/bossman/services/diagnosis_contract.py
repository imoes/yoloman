"""The diagnosis contract — the one check of a Diagnosis document, used by the contract tests and by Bossman on
ingest (an agent in the fleet may be older than this Bossman, so its documents are checked, never trusted).

Two layers:
  - configs/schemas/diagnosis.schema.json — the SHAPE (JSON Schema 2020-12);
  - `violations()` — what a schema cannot say: every cited evidence exists, a target that is not running has a
    finding, the timeline is the observed evidence in time order, each rule exists in configs/diagnosis_rules.json,
    applies to the platform and does not claim more certainty than the catalogue allows.

A violation is reported by name, never repaired: a document with violations is stored as such (formal-logic rule:
nothing vanishes silently, and nothing is quietly made true).
"""

from __future__ import annotations

import json
from datetime import datetime
from functools import lru_cache

from bossman.tools._paths import configs_dir

CONFIGS = configs_dir(__file__)
SCHEMA_PATH = CONFIGS / "schemas" / "diagnosis.schema.json"
RULES_PATH = CONFIGS / "diagnosis_rules.json"
_RANK = {"Unknown": 0, "Likely": 1, "Proven": 2}


@lru_cache(maxsize=1)
def schema() -> dict:
    return json.loads(SCHEMA_PATH.read_text())


@lru_cache(maxsize=1)
def rules() -> dict:
    return json.loads(RULES_PATH.read_text())["rules"]


def _time(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def schema_errors(doc: dict) -> list[str]:
    """Shape errors, each with its JSON path."""
    import jsonschema  # local: only the contract check needs it

    validator = jsonschema.Draft202012Validator(schema(), format_checker=jsonschema.FormatChecker())
    return [f"{'/'.join(str(p) for p in e.absolute_path) or '<root>'}: {e.message}"
            for e in sorted(validator.iter_errors(doc), key=lambda e: list(e.absolute_path))]


def violations(doc: dict) -> list[str]:
    """Every contract violation of a document, each a sentence naming what is wrong. Empty = the document holds."""
    out = schema_errors(doc)
    if out:
        return out          # the cross-checks below assume the shape
    catalogue = rules()
    evidence = {e["id"]: e for e in doc["evidence"]}
    if len(evidence) != len(doc["evidence"]):
        out.append("evidence ids are not unique")
    for i, f in enumerate(doc["findings"]):
        where = f"findings/{i} ({f['rule_id']})"
        rule = catalogue.get(f["rule_id"])
        if rule is None:
            out.append(f"{where}: rule is not in configs/diagnosis_rules.json")
            continue
        if doc["platform"] not in rule["platforms"]:
            out.append(f"{where}: rule does not apply to platform {doc['platform']}")
        if _RANK[f["certainty"]] > _RANK[rule["certainty"]]:
            out.append(f"{where}: certainty {f['certainty']} exceeds the rule's maximum {rule['certainty']}")
        dangling = [x for x in f["evidence_ids"] if x not in evidence]
        if dangling:
            out.append(f"{where}: cites evidence that is not in the diagnosis: {', '.join(dangling)}")
        p = f.get("precedent")
        if p:
            if p["evidence_id"] not in evidence:
                out.append(f"{where}: precedent cites evidence that is not in the diagnosis: {p['evidence_id']}")
            if f["evidence_ids"] == [p["evidence_id"]]:
                out.append(f"{where}: the only evidence is the precedent — a preceding change is a correlation, "
                           "not a cause")
        r = f.get("remedy")
        if r and r["target"]["kind"] not in rule["remedy_kinds"]:
            out.append(f"{where}: remedy kind {r['target']['kind']} is not one the rule offers")
    if doc["status"] in ("stopped", "failed", "not-found", "unknown") and not doc["findings"]:
        out.append(f"status is {doc['status']} but there is no finding — svc.unexplained (Unknown, with the gap) "
                   "is the finding for 'no rule matched'")
    observed = sorted(((_time(e["observed"]), e["id"]) for e in doc["evidence"] if e["observed"]),
                      key=lambda t: t[0])
    timeline = [(_time(t["observed"]), t["evidence_id"]) for t in doc["timeline"]]
    if [t for t, _ in timeline] != sorted(t for t, _ in timeline):
        out.append("timeline is not in time order")
    if sorted(x for _, x in timeline) != sorted(x for _, x in observed):
        out.append("timeline must list exactly the evidence that has an observed time")
    for t, x in timeline:
        if x in evidence and evidence[x]["observed"] and _time(evidence[x]["observed"]) != t:
            out.append(f"timeline entry {x} has another time than its evidence")
    return out


def catalogue_violations() -> list[str]:
    """The rule catalogue itself: unique order, known platforms and certainties."""
    out = []
    orders: dict[int, str] = {}
    for rid, r in rules().items():
        if r["order"] in orders:
            out.append(f"{rid}: order {r['order']} is also used by {orders[r['order']]}")
        orders[r["order"]] = rid
        if not set(r["platforms"]) <= {"windows", "linux"}:
            out.append(f"{rid}: unknown platform in {r['platforms']}")
        if r["certainty"] not in _RANK:
            out.append(f"{rid}: unknown certainty {r['certainty']}")
        kind = {"Proven": "proven_when", "Likely": "likely_when", "Unknown": "unknown_when"}[r["certainty"]]
        if not set(r.get(kind) or {}) >= set(r["platforms"]):
            out.append(f"{rid}: {kind} does not say for every platform when the rule fires")
    return out


def examples() -> dict[str, dict]:
    return {p.stem: json.loads(p.read_text())
            for p in sorted((CONFIGS / "schemas" / "diagnosis.examples").glob("*.json"))}


def remedy_kinds() -> list[str]:
    return schema()["$defs"]["remedy"]["properties"]["target"]["properties"]["kind"]["enum"]

