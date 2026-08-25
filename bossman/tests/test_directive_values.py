"""The directive catalog's value sets — the same two rules the template side already applies.

`config_directives.json` feeds the gpedit/OU policy editor and the codec MERGE write path. Measured before
this: 43 463 keys, 99.5% with a description, 10.6% with a value set — and 361 of those sets held exactly one
option.
"""

import pytest

from bossman.tools.directive_values import process


def test_a_stated_set_is_read_from_the_description():
    catalog = {"/etc/x.conf": {"log_level": {
        "type": "string", "description": "Verbosity. Options: debug, info, warning, error."}}}
    out, decisions = process(catalog)
    assert out["/etc/x.conf"]["log_level"]["values"] == ["debug", "info", "warning", "error"]
    assert decisions[0]["action"] == "added"


def test_a_numeric_mapping_brings_its_labels():
    catalog = {"/etc/fw.conf": {"POLICY_DROP": {
        "type": "string", "description": "Default policy (1=DROP, 0=ACCEPT, empty=automatic)"}}}
    out, _ = process(catalog)
    entry = out["/etc/fw.conf"]["POLICY_DROP"]
    assert entry["values"] == ["1", "0"]
    # The label stops at the top-level comma: "empty=automatic" is the NEXT mapping, in a form the numeric
    # loop does not recognise, and it used to become part of value 0's label.
    assert entry["value_labels"] == {"1": "DROP", "0": "ACCEPT"}


def test_a_one_option_set_is_dropped_with_its_reason():
    """`AllowOverride: ["None"]` when Apache also accepts All, AuthConfig and FileInfo. A one-option dropdown
    does not look odd, it REMOVES every legal value from the operator's reach."""
    catalog = {"/etc/apache2/apache2.conf": {"AllowOverride": {
        "type": "string", "values": ["None"],
        "description": "Which directives in .htaccess files are allowed."}}}
    out, decisions = process(catalog)
    entry = out["/etc/apache2/apache2.conf"]["AllowOverride"]
    assert "values" not in entry and "enum" not in entry
    assert entry["description"], "the description must survive — it is all the operator has left"
    assert decisions[0]["action"] == "dropped"
    assert decisions[0]["was"] == ["None"]
    assert "not a choice" in decisions[0]["reason"]


def test_a_real_set_is_left_alone():
    catalog = {"/etc/x.conf": {"mode": {"type": "string", "values": ["fast", "slow"],
                                        "description": "Options: fast, slow"}}}
    out, decisions = process(catalog)
    assert out["/etc/x.conf"]["mode"]["values"] == ["fast", "slow"]
    assert decisions == [], "an existing real set is not a decision to report"


@pytest.mark.parametrize("type_name, values", [
    # A bool with literals is RIGHT: the type says two-state, the values say which words the file wants.
    # A checkbox would submit `true` where the file needs `On`.
    ("bool", ["On", "Off"]),
    # A list with an item set is a multi-select, not a single choice.
    ("list", ["LVM", "MD", "PARTITION"]),
    ("int", ["0", "1"]),
])
def test_other_types_keep_their_own_control(type_name, values):
    catalog = {"/etc/x.conf": {"k": {"type": type_name, "values": values, "description": "d"}}}
    out, _ = process(catalog)
    assert out["/etc/x.conf"]["k"]["values"] == values
    assert out["/etc/x.conf"]["k"]["type"] == type_name


def test_multi_word_values_are_not_prose():
    """`Require: all denied|all granted` is Apache's real value set, `map to guest: bad user` is Samba's. A
    "looks like prose" filter flagged 26 such keys and 25 were correct, which is why there is none."""
    catalog = {"/etc/apache2/apache2.conf": {"Require": {
        "type": "string", "description": "Access control: 'all denied' or 'all granted'."}}}
    out, _ = process(catalog)
    assert out["/etc/apache2/apache2.conf"]["Require"]["values"] == ["all denied", "all granted"]


def test_a_value_equal_to_the_key_name_is_refused():
    """"Target username for 'user' or 'direct' actions" on the key `user`: the quoted words are the values of
    a DIFFERENT setting, and this one holds a username."""
    catalog = {"/etc/bti": {"user": {
        "type": "string", "description": "Target username for 'user' or 'direct' actions."}}}
    out, decisions = process(catalog)
    assert "values" not in out["/etc/bti"]["user"]
    assert "own name" in decisions[0]["reason"]


def test_a_dropped_one_option_set_can_be_replaced_by_the_stated_one():
    """The better outcome, and both steps are recorded in order: the one-option set goes, then the
    description's real set arrives — a dropdown instead of free text."""
    catalog = {"/etc/x.conf": {"mode": {
        "type": "string", "values": ["fast"], "description": "Options: fast, slow"}}}
    out, decisions = process(catalog)
    assert out["/etc/x.conf"]["mode"]["values"] == ["fast", "slow"]
    assert [d["action"] for d in decisions] == ["dropped", "added"]


def test_running_twice_changes_nothing():
    catalog = {"/etc/x.conf": {"log_level": {"type": "string", "description": "Options: debug, info"}}}
    once, _ = process(catalog)
    snapshot = str(once)
    twice, decisions = process(once)
    assert str(twice) == snapshot
    assert [d for d in decisions if d["action"] != "none"] == []
