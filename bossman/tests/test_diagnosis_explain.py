"""The explanation check (plan B11) with prepared model answers — no model needed, and none is called."""

import asyncio
import json
from pathlib import Path

from bossman.services import diagnosis_explain as E

EXAMPLES = Path(__file__).resolve().parents[2] / "configs/schemas/diagnosis.examples"


def golden(name: str) -> dict:
    return json.loads((EXAMPLES / f"{name}.json").read_text())


class CannedModel:
    def __init__(self, sentences=None, fail=False):
        self.sentences, self.fail, self.calls = sentences, fail, []

    async def complete_json(self, messages, json_schema, schema_name, max_tokens=None, extra_body=None):
        self.calls.append({"max_tokens": max_tokens, "extra_body": extra_body, "schema": schema_name})
        if self.fail:
            raise RuntimeError("503 Loading model")
        return {"sentences": self.sentences}


def run(doc, model):
    return asyncio.run(E.explain(doc, model, language="de"))


DOC = golden("windows-logon-right")
RIGHTS = next(e["id"] for e in DOC["evidence"] if e["id"].startswith("lsa:rights:"))
STATUS = next(e["id"] for e in DOC["evidence"] if e["id"].startswith("scm:status:"))


def test_a_backed_sentence_passes_and_the_model_is_called_without_a_token_cap():
    m = CannedModel([{"text": "Dem Konto .\\probeuser fehlt das Recht SeServiceLogonRight.", "evidence_ids": [RIGHTS]}])
    out = run(DOC, m)
    assert out["source"] == "model" and out["unbacked"] == 0, out["sentences"]
    assert m.calls[0]["max_tokens"] is None
    assert m.calls[0]["extra_body"] == {"chat_template_kwargs": {"enable_thinking": False}}


def test_an_invented_id_is_not_backed():
    out = run(DOC, CannedModel([{"text": "Der Dienst startet nicht.", "evidence_ids": ["evt:System:7000:1"]}]))
    assert out["sentences"][0]["backed"] is False and "not in the diagnosis" in out["sentences"][0]["why"]


def test_a_sentence_without_ids_is_not_backed():
    out = run(DOC, CannedModel([{"text": "Das Konto darf sich nicht als Dienst anmelden.", "evidence_ids": []}]))
    assert out["sentences"][0]["why"] == "cites no evidence"


def test_a_wrong_exit_code_is_caught():
    out = run(DOC, CannedModel([{"text": "Der Start scheiterte mit Fehler 1053.", "evidence_ids": [STATUS]}]))
    assert out["sentences"][0]["backed"] is False and "1053" in out["sentences"][0]["why"]


def test_a_certainty_in_the_prose_is_refused():
    out = run(DOC, CannedModel([{"text": "Ganz sicher fehlt das Recht SeServiceLogonRight.", "evidence_ids": [RIGHTS]}]))
    assert "states a certainty" in out["sentences"][0]["why"]


def test_an_omitted_unknown_still_appears_in_the_code_written_header():
    doc = golden("unknown-gap")
    some = doc["evidence"][0]["id"]
    out = run(doc, CannedModel([{"text": "Der Dienst lief nicht.", "evidence_ids": [some]}]))
    gap = doc["findings"][0]["gap"]
    assert any(line.startswith("Unknown: ") and gap in line for line in out["header"])


def test_no_model_falls_back_to_the_template_and_says_so():
    out = run(DOC, CannedModel(fail=True))
    assert out["source"] == "template" and "did not answer" in out["note"] and out["unbacked"] == 0
    assert out["sentences"][0]["text"] == DOC["findings"][0]["claim"]


def test_a_german_compound_is_prose_not_a_name():
    out = run(DOC, CannedModel([{"text": "Das Remediation-Verfahren bleibt offen.", "evidence_ids": [RIGHTS]},
                               {"text": "Der Dienst yoloman-probe-other startet nicht.", "evidence_ids": [RIGHTS]}]))
    assert out["sentences"][0]["backed"] is True
    assert out["sentences"][1]["backed"] is False and "yoloman-probe-other" in out["sentences"][1]["why"]


def test_a_hex_value_in_another_spelling_and_the_claims_own_words_are_backed():
    doc = {"findings": [{"rule_id": "svc.crash", "certainty": "Proven", "evidence_ids": ["evt:Application:1000:1"],
                         "claim": "It did not report as started within the SCM's 30 s start timeout."}],
           "evidence": [{"id": "evt:Application:1000:1", "source": "EventLog/Application", "fact": "application error",
                         "raw": {"data": ["ProbeService.exe", "e0434352"]}}],
           "target": {"name": "probe"}, "status": "stopped"}
    out = E.check(doc, [{"text": "Die Ausnahme 0xE0434352 kam nach dem 30-Sekunden-Timeout.", "evidence_ids": ["evt:Application:1000:1"]}])
    assert out[0]["backed"] is True, out[0]["why"]
    bad = E.check(doc, [{"text": "Die Ausnahme 0xC0000005 kam.", "evidence_ids": ["evt:Application:1000:1"]}])
    assert bad[0]["backed"] is False and "0xc0000005" in bad[0]["why"]
