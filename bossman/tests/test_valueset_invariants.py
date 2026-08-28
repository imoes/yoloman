"""The invariants a value set must satisfy, and the ordering bug that made them one function.

Five passes write the same two catalogs. Spread over five files their rules interacted: `mark_open_enums`
DEDUPLICATED `['LOG_DAEMON', 'LOG_DAEMON']` into `['LOG_DAEMON']` — a one-option set, after the pass that
removes those had already run. Two correct rules in the wrong order produced the thing both forbid, and it was
found by a later pass offering to COPY that one-option set into the other catalog.
"""

import pytest

from bossman.tools._valuesets import dedupe, normalise


@pytest.mark.parametrize("values, expected", [
    (["r--", "r--", "rw-"], ["r--", "rw-"]),
    (["z", "a", "z", "b"], ["z", "a", "b"]),      # first occurrence wins, order preserved
    ([1, "1", 2], [1, 2]),                        # 1 and "1" are the same OPTION in a menu
    (["a", "b"], ["a", "b"]),
])
def test_dedupe(values, expected):
    assert dedupe(values) == expected


def test_deduplicating_down_to_one_drops_the_set():
    """THE BUG THIS FILE EXISTS FOR. Deduplication alone left a one-option dropdown behind."""
    spec = {"enum": ["LOG_DAEMON", "LOG_DAEMON"], "description": "Syslog facility"}
    why = normalise(spec, "template")
    assert "enum" not in spec
    assert "fewer than two" in why and "after duplicate" in why
    assert spec["description"], "the description survives — it is all the operator has left"


def test_a_one_option_set_goes_with_its_labels_and_its_open_mark():
    spec = {"values": ["only"], "value_labels": {"only": "the one"}, "enum_open": True, "description": "d"}
    why = normalise(spec, "directive")
    assert "values" not in spec and "value_labels" not in spec and "enum_open" not in spec
    assert why


def test_a_real_set_is_untouched():
    spec = {"enum": ["a", "b", "c"], "enum_labels": {"a": "A"}, "enum_open": True}
    assert normalise(spec, "template") == ""
    assert spec["enum"] == ["a", "b", "c"]
    assert spec["enum_open"] is True


def test_orphaned_labels_are_removed():
    """A label for a value that is gone answers a question nobody can ask."""
    spec = {"enum": ["a", "a", "b"], "enum_labels": {"a": "A", "gone": "G"}}
    why = normalise(spec, "template")
    assert spec["enum"] == ["a", "b"]
    assert spec["enum_labels"] == {"a": "A"}
    assert "orphaned" in why


def test_the_label_map_is_dropped_when_nothing_is_left_to_label():
    spec = {"enum": ["a", "b"], "enum_labels": {"gone": "G"}}
    normalise(spec, "template")
    assert "enum_labels" not in spec


@pytest.mark.parametrize("shape, set_key, label_key", [
    ("directive", "values", "value_labels"),
    ("template", "enum", "enum_labels"),
])
def test_both_spellings(shape, set_key, label_key):
    """The directive catalog and a template schema name the same thing differently; the translation lives in
    one place rather than in each caller."""
    spec = {set_key: ["x", "x"], label_key: {"x": "X"}}
    normalise(spec, shape)
    assert spec.get(set_key) is None, "a one-option set after dedupe must go, whatever it is called"


def test_a_field_with_no_set_at_all_is_not_a_decision():
    spec = {"type": "string", "description": "free text"}
    assert normalise(spec, "template") == ""
    assert spec == {"type": "string", "description": "free text"}
