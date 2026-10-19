"""An explanation of a diagnosis for a person — the AI phrases, the code checks (plan B11).

The agent decided the findings and their certainty; nothing here changes them. A language model may only put the
document into sentences, and it must hand them back STRUCTURED — `[{text, evidence_ids}]` — so no German prose has
to be split into sentences afterwards. Then a deterministic check marks a sentence `backed: false`, with the reason,
when it

- cites no evidence, or an evidence id that is not in the diagnosis;
- states a certainty itself ("sicher", "probably", "Proven" …) — certainty is written by the code, verbatim;
- names something specific — a service or account name, an error or exit code, a number, a time — that is not in the
  fact, the raw data or the time of the evidence it cites.

The header (each finding's certainty and claim, every gap word for word) is written by the code, never by the model,
so an explanation that leaves out an Unknown cannot hide it. Without a model the sentences come from a template over
the findings, through the same check. `check()` is also what the MCP tool `check_explanation` runs on the sentences
a calling AI wrote itself.
"""

from __future__ import annotations

import json
import re
from typing import Any

SCHEMA = {
    "type": "object", "additionalProperties": False, "required": ["sentences"],
    "properties": {"sentences": {"type": "array", "items": {
        "type": "object", "additionalProperties": False, "required": ["text", "evidence_ids"],
        "properties": {"text": {"type": "string"}, "evidence_ids": {"type": "array", "items": {"type": "string"}}}}}},
}

# Words that state a certainty. The explanation may not: the finding's certainty is printed by the code.
_CERTAINTY = re.compile(r"(?i)\b(proven|likely|unknown|certain(ly)?|definite(ly)?|probabl[ey]|surely|undoubtedly|"
                        r"bewiesen|sicher(lich)?|eindeutig|definitiv|wahrscheinlich|vermutlich|zweifellos|unbekannt)\b")
# Specific tokens a sentence must be able to back: anything with a digit; identifiers with - _ . \ $ @ : inside;
# CamelCase words (SeServiceLogonRight, LocalSystem).
_TOKEN = re.compile(r"[\w.\\$@:%-]*\d[\w.\\$@:%-]*|[\w$]+(?:[-_.\\@:][\w$]+)+|\.\\[\w$-]+|\b[A-Z][a-z]+(?:[A-Z][a-z0-9]+)+\b")

SYSTEM = (
    "You explain a service diagnosis to an administrator. You receive the findings (already decided, with their "
    "certainty) and the evidence (each with an id and a fact). Write 2 to 6 short sentences that explain what is "
    "wrong, why, what changed before, and what the remedy would do. Rules: every sentence lists the evidence ids it "
    "rests on; copy names, numbers, codes and times exactly as they appear in the facts; never state a certainty "
    "(no 'sure', 'probably', 'proven' — the certainty is shown separately); never add a cause that is not a finding; "
    "a preceding change is a correlation, not a cause. Answer as JSON {\"sentences\": [{\"text\", \"evidence_ids\"}]}."
)


def header(doc: dict) -> list[str]:
    """Certainty and gaps, written by the code — the part no explanation can change or drop."""
    out = []
    for f in doc.get("findings") or []:
        line = f"{f['certainty']}: {f['claim']}"
        if f.get("gap"):
            line += f" Not measurable: {f['gap']}"
        if p := f.get("precedent"):
            line += f" Preceded {p['gap_seconds']} s earlier by: {p['change']} (a correlation, not a cause)."
        if r := f.get("remedy"):
            line += (f" Remedy offered: {r['action']} {r['target']['kind']} {r['target']['id']} — verified when "
                     f"{r['verify']['rule_absent']} is gone.")
        out.append(line)
    out += [f"Not observable — {g['what']}: {g['why']}" for g in doc.get("gaps") or []]
    if not doc.get("findings"):
        out.insert(0, doc.get("summary") or f"{doc.get('target', {}).get('name')} is {doc.get('status')}.")
    return out


def _haystack(doc: dict, ids: list[str]) -> str:
    ev = {e["id"]: e for e in doc.get("evidence") or []}
    parts = []
    for i in ids:
        e = ev.get(i)
        if e:
            parts += [e["id"], e["fact"], json.dumps(e.get("raw"), ensure_ascii=False), str(e.get("observed") or "")]
    return "\n".join(parts).lower()


def _allowed_words(doc: dict) -> set[str]:
    # the document's own vocabulary that needs no evidence: rule ids and the target's name (the subject of it all)
    out = {f["rule_id"].lower() for f in doc.get("findings") or []}
    t = doc.get("target") or {}
    out |= {str(t.get("name") or "").lower(), str(t.get("display_name") or "").lower()}
    return {w for w in out if w}


def _claims_citing(doc: dict, ids: list[str]) -> str:
    """The code-written claims of the findings that cite any of these evidences — trusted vocabulary (a rule's own
    knowledge, e.g. the SCM's 30 s start timeout, is in the claim, not in a measurement)."""
    wanted = set(ids)
    return "\n".join(f["claim"] for f in doc.get("findings") or [] if wanted & set(f.get("evidence_ids") or [])).lower()


def _hex_variants(tok: str) -> list[str]:
    # "0xE0434352" in prose, "e0434352" in the event — one value in two spellings (found on the first crash explanation)
    if tok.startswith("0x") and len(tok) > 2:
        return [tok, tok[2:], tok[2:].lstrip("0") or "0"]
    return [tok]


def check(doc: dict, sentences: list[dict[str, Any]]) -> list[dict[str, Any]]:
    known = {e["id"] for e in doc.get("evidence") or []}
    allowed = _allowed_words(doc)
    out = []
    for s in sentences:
        text = str(s.get("text") or "").strip()
        ids = [str(i) for i in s.get("evidence_ids") or []]
        why: list[str] = []
        if not ids:
            why.append("cites no evidence")
        foreign = [i for i in ids if i not in known]
        if foreign:
            why.append("cites evidence that is not in the diagnosis: " + ", ".join(foreign))
        m = _CERTAINTY.search(text)
        if m:
            why.append(f"states a certainty (\"{m.group(0)}\") — the certainty is the finding's, shown by the code")
        cited = [i for i in ids if i in known]
        hay = _haystack(doc, cited) + "\n" + _claims_citing(doc, cited)
        missing = []
        for tok in _TOKEN.findall(text):
            raw_tok = tok.strip(".,;:()[]\"'")
            # A hyphenated compound of capitalised words ("Remediation-Verfahren", "Start-Limit") is German prose,
            # not a name — found on the first live run. Names are written lowercase (yoloman-probe-lsa) or carry
            # digits, dots, backslashes or underscores.
            if re.fullmatch(r"[A-ZÄÖÜ][\wäöüß]*(?:-[A-ZÄÖÜ][\wäöüß]*)+", raw_tok) and not re.search(r"\d", raw_tok):
                continue
            t = raw_tok.lower()
            found = any(v in hay for v in _hex_variants(t))
            if not found and "-" in t and not re.search(r"[._\\$@:]", t):
                # a compound with a number ("30-Sekunden-Timeout"): the NUMBER is the specific claim, the words are prose
                digits = [x for x in t.split("-") if any(ch.isdigit() for ch in x)]
                found = bool(digits) and all(any(v in hay for v in _hex_variants(x)) for x in digits)
            if t and t not in allowed and not found and t not in missing:
                missing.append(t)
        if missing and ids and not foreign:
            why.append("names what the cited evidence does not contain: " + ", ".join(missing))
        out.append({"text": text, "evidence_ids": ids, "backed": not why, "why": "; ".join(why) or None})
    return out


def template(doc: dict) -> list[dict[str, Any]]:
    """Sentences without a model: each finding's claim with its evidence, and its precedent as a correlation (the
    remedy is in the header — it is the agent's proposal, not a measurement a sentence could cite)."""
    out: list[dict[str, Any]] = []
    for f in doc.get("findings") or []:
        out.append({"text": f["claim"], "evidence_ids": f["evidence_ids"]})
        if p := f.get("precedent"):
            # the measured time, not the computed seconds: the sentence must stand on its evidence
            out.append({"text": f"Before that, at {p['observed']}: {p['change']} — a correlation, not a cause.",
                        "evidence_ids": [p["evidence_id"]]})
    return out


def _prompt(doc: dict, language: str) -> list[dict[str, str]]:
    body = {
        "language": language,
        "target": doc.get("target"), "status": doc.get("status"),
        "findings": [{k: f.get(k) for k in ("rule_id", "certainty", "claim", "evidence_ids", "precedent", "remedy", "gap")}
                     for f in doc.get("findings") or []],
        "evidence": [{"id": e["id"], "fact": e["fact"], "observed": e.get("observed")} for e in doc.get("evidence") or []],
    }
    return [{"role": "system", "content": SYSTEM},
            {"role": "user", "content": f"Write the sentences in {language}.\n" + json.dumps(body, ensure_ascii=False)}]


async def explain(doc: dict, client: Any | None = None, language: str = "en") -> dict[str, Any]:
    """The explanation: code-written header + checked sentences. `client` is a ChatClient (or None → template)."""
    source, note, raw = "template", None, template(doc)
    if client is not None:
        try:
            # thinking off, no token cap (CLAUDE.md: never max_tokens — a cut-off answer is fixed by thinking off)
            res = await client.complete_json(_prompt(doc, language), SCHEMA, "diagnosis_explanation",
                                             extra_body={"chat_template_kwargs": {"enable_thinking": False}})
            raw, source = list(res.get("sentences") or []), "model"
        except Exception as exc:  # noqa: BLE001 — no model is a named fallback, not a failure of the explanation
            note = f"the model did not answer ({type(exc).__name__}: {str(exc)[:200]}); the sentences are the template"
    sentences = check(doc, raw)
    return {"source": source, "note": note, "header": header(doc), "sentences": sentences,
            "unbacked": sum(1 for s in sentences if not s["backed"])}
