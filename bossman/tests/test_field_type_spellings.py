"""One spelling per type, and a boolean default written in the file's own words.

Two defects with the same shape — a value or a type that is correct in one vocabulary and meaningless in the
one that reads it:

  * 427 template fields say `type: "boolean"` and 62 say `"integer"`, JSON-Schema's words. The form renderer
    knows only this project's (`bool`, `int`, `list`), so every one of them rendered as a TEXT BOX where a
    checkbox or a number field belongs.
  * 25 fields are typed `string` and carry `default: true` — a JSON boolean, which `template_render`
    substitutes verbatim, so the file receives `True` with a capital T.
"""

import pytest

from bossman.api.config_fields import _field_from_directive, _spell_types
from bossman.tools.fix_bool_defaults import vocabulary_of


@pytest.mark.parametrize("stored, served", [
    ("boolean", "bool"),        # JSON-Schema's word for this project's
    ("integer", "int"),
    ("array", "list"),
    ("flat_map", "object"),
    ("number", "number"),
    # A UNION resolves to the PERMISSIVE side: a text box accepts everything a checkbox would, not the
    # reverse. Two fields in the corpus are spelled each way round.
    ("bool|string", "string"),
    ("string|bool", "string"),
    (None, "string"),
    ("", "string"),
    # already this project's spelling — untouched
    ("bool", "bool"),
    ("string", "string"),
    ("list", "list"),
])
def test_a_type_is_served_in_one_spelling(stored, served):
    fields = _spell_types({"k": {"type": stored}})
    assert fields["k"]["type"] == served


def test_the_directive_branch_spells_types_the_same_way():
    """Both branches of /config-fields answer the same question, so a type cannot mean two things depending
    on which one replied."""
    assert _field_from_directive({"type": "boolean"})["type"] == "bool"
    assert _field_from_directive({"type": "integer"})["type"] == "int"
    # A value set still wins over the type word — that is the older translation and it stays.
    assert _field_from_directive({"type": "boolean", "values": ["On", "Off"]})["type"] == "enum"


def test_spelling_leaves_everything_else_alone():
    fields = _spell_types({"k": {"type": "boolean", "default": "yes", "description": "d", "enum": ["a", "b"]}})
    assert fields["k"] == {"type": "bool", "default": "yes", "description": "d", "enum": ["a", "b"]}


# --------------------------------------------------------------------------- boolean defaults

@pytest.mark.parametrize("sample, pair", [
    ("yes", ("yes", "no")), ("no", ("yes", "no")), ("YES", ("yes", "no")),
    ("true", ("true", "false")), ("false", ("true", "false")),
    ("on", ("on", "off")), ("off", ("on", "off")),
])
def test_the_vocabulary_is_learned_from_the_sample(sample, pair):
    assert vocabulary_of(sample) == pair


@pytest.mark.parametrize("sample", [
    # NOT two-state at all: these fields' boolean default is simply wrong and no vocabulary repairs it.
    "gallery-dl-{id}.zip", "auto", "", None, 1, True, "somethingelse",
])
def test_a_non_boolean_sample_teaches_nothing(sample):
    assert vocabulary_of(sample) is None


def test_the_sample_is_not_taken_AS_the_default():
    """`dyn-netconf/dhcp` has `default: true` beside `sample: 'false'` — the sample is an example of the
    SYNTAX, not a statement about the default. Only the vocabulary is learned from it; the truth value comes
    from the default that is already there."""
    pair = vocabulary_of("false")
    assert pair == ("true", "false")
    assert pair[0] == "true", "default true must map to the file's word for true, not to the sample"
