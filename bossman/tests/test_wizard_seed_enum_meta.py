"""The wizard's parameter mask keeps what /config-fields keeps.

A schema field carries `enum_labels` (what each opaque value means) and `enum_open` (the values are
suggestions, not the whole range). The wizard seed used to copy only `enum`, so the same field showed
"0 · 1 · 2 · 3" in the wizard and "0 — quiet · 1 — normal …" in the config editor, and an open list was
closed in one place and open in the other. One field, one shape, in both places.
"""

from bossman.services.wizard_seed import _build_parameters, _params_from_play_vars

ENTRY = {"families": {"debian": {"packages": ["demo"], "config_path": "/etc/demo.conf", "service": "demo"}}}


def test_schema_enum_labels_and_open_reach_the_mask():
    schema = {
        "log_level": {"type": "int", "default": 1, "enum": [0, 1, 2],
                      "enum_labels": {"0": "quiet", "1": "normal", "2": "debug"}},
        "facility": {"type": "string", "enum": ["daemon", "user"], "enum_open": True},
        "plain": {"type": "string", "enum": ["a", "b"]},
    }
    params = _build_parameters(schema, {}, ENTRY)
    assert params["log_level"]["enum_labels"] == {"0": "quiet", "1": "normal", "2": "debug"}
    assert params["facility"]["enum_open"] is True
    # A closed, unlabelled list stays exactly that — no invented keys.
    assert "enum_labels" not in params["plain"] and "enum_open" not in params["plain"]


def test_directive_value_labels_reach_the_mask_under_the_schema_name():
    # The directive catalog spells the label map `value_labels`; the mask uses the one name ParamForm reads.
    directives = {"mode": {"type": "enum", "values": ["a", "b"], "value_labels": {"a": "alpha"}, "enum_open": True}}
    params = _build_parameters({"mode": {"type": "string"}}, directives, ENTRY)
    assert params["mode"]["enum"] == ["a", "b"]
    assert params["mode"]["enum_labels"] == {"a": "alpha"}
    assert params["mode"]["enum_open"] is True


def test_playbook_vars_inherit_the_schema_annotations():
    # The generated playbook is the source of truth for the mask; the schema enriches it — labels included.
    schema_params = _build_parameters(
        {"log_level": {"type": "int", "enum": [0, 1], "enum_labels": {"0": "quiet", "1": "loud"}, "enum_open": True}},
        {}, ENTRY,
    )
    params = _params_from_play_vars({"log_level": 0}, schema_params)
    assert params["log_level"]["enum"] == [0, 1]
    assert params["log_level"]["enum_labels"] == {"0": "quiet", "1": "loud"}
    assert params["log_level"]["enum_open"] is True
