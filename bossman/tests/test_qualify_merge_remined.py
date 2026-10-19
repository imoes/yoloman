"""A re-mine of a path keeps what later stages added (merge_remined)."""

from bossman.tools.qualify_packages import merge_remined


def test_open_mark_survives_a_remine_of_the_same_set():
    old = {"protocol": {"type": "enum", "values": ["dyndns2", "cloudflare"], "enum_open": True,
                        "description": "Dynamic DNS service protocol to use."}}
    mined = {"protocol": {"type": "enum", "values": ["cloudflare", "dyndns2"], "description": "DDNS protocol"}}
    out = merge_remined(old, mined)
    assert out["protocol"]["enum_open"] is True
    assert out["protocol"]["description"] == "DDNS protocol"


def test_marks_do_not_travel_to_a_different_set():
    old = {"mode": {"values": ["a", "b"], "enum_open": True, "value_labels": {"a": "A"}}}
    out = merge_remined(old, {"mode": {"values": ["x", "y"]}})
    assert "enum_open" not in out["mode"] and "value_labels" not in out["mode"]


def test_curated_description_and_unreported_keys_are_kept():
    old = {"a": {"description": "curated", "description_source": "man"}, "gone": {"type": "string"}}
    out = merge_remined(old, {"a": {"description": "llm", "type": "string"}})
    assert out["a"]["description"] == "curated" and out["a"]["description_source"] == "man"
    assert out["gone"] == {"type": "string"}


def test_first_mine_is_taken_as_is():
    assert merge_remined(None, {"k": {"type": "string"}}) == {"k": {"type": "string"}}


def test_a_hand_built_template_is_curated(tmp_path, monkeypatch):
    import json

    from bossman.tools import qualify_packages as q

    (tmp_path / "mine").mkdir()
    (tmp_path / "mine" / "meta.json").write_text(json.dumps({"source": "hand"}))
    (tmp_path / "drafted").mkdir()
    (tmp_path / "drafted" / "meta.json").write_text(json.dumps({"source": "qualify"}))
    monkeypatch.setattr(q, "TEMPLATES_DIR", tmp_path)
    assert q._curated("mine") and not q._curated("drafted") and not q._curated("absent")
