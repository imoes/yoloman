"""The fit check itself, and the type repair it uncovered.

Five passes and a nightly LLM batch write the same catalogs. Every rule the check enforces was learned from a
defect that reached the editor — so the check exists to stop them being rediscovered, and its own first run
found 19 violations nobody had looked for, including a field whose declared `type` was the sentence
"Port the agent listens on for incoming requests."
"""

import pytest

from bossman.tools.check_catalog_fit import KNOWN_TYPES, TRANSLATED_TYPES
from bossman.tools.fix_broken_types import from_default, repair


@pytest.mark.parametrize("default, expected", [
    (True, "bool"), (False, "bool"),
    (4, "number"), (1.5, "number"),
    (["a"], "list"), ({"k": "v"}, "object"),
    ("x", "string"), (None, "string"),
])
def test_the_default_says_which_control(default, expected):
    """A type word that is not a type has to be replaced by something, and the field's own default is the
    only evidence on hand about its shape."""
    assert from_default(default) == expected


def test_a_sentence_is_not_a_type():
    spec = {"type": "Port the agent listens on for incoming requests.", "default": 5353}
    new, why = repair(spec)
    assert new == "number"
    assert "not a type" in why


def test_a_fragment_is_not_a_type():
    spec = {"type": ":{"}
    assert repair(spec)[0] == "string"


@pytest.mark.parametrize("union, expected", [
    # The permissive member wins — the same rule the serving layer applies to bool|string: a text box
    # accepts what a number field refuses.
    ("string|null", "string"),
    ("number|list", "list"),
    ("int|string", "string"),
])
def test_a_union_resolves_to_its_permissive_member(union, expected):
    new, why = repair({"type": union})
    assert new == expected
    assert "union" in why


def test_a_nested_spec_is_unwrapped_not_guessed():
    """The generator wrote the field twice, one inside the other's `type`. The inner one IS the field, so its
    own keys are lifted rather than invented."""
    spec = {"type": {"type": "string", "default": "docker", "description": "the builder"}}
    new, why = repair(spec)
    assert new == "string"
    assert spec["default"] == "docker", "the inner spec's default must survive the unwrapping"
    assert spec["description"] == "the builder"
    assert "nested spec" in why


@pytest.mark.parametrize("good", ["string", "bool", "int", "number", "list", "object", "enum", "boolean"])
def test_a_known_type_is_left_alone(good):
    assert repair({"type": good}) is None


def test_a_missing_type_is_taken_from_the_default():
    new, why = repair({"default": True})
    assert new == "bool" and "no type at all" in why


def test_every_translated_type_is_also_a_known_one():
    """The two lists are kept explicit so they cannot drift: a word the serving layer translates but the
    check rejects would fail the check on a catalog that is correct."""
    assert TRANSLATED_TYPES <= KNOWN_TYPES
