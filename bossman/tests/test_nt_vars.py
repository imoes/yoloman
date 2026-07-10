"""Block G11 step 2 — NT variable substitution (all bracket styles + bash
modifiers, native-type whole-match, GPO scope merge)."""

import pytest

from bossman.services.nt_vars import NTVarError, merge_scopes, substitute, substitute_str

VARS = {"host": "db01", "port": 3306, "empty": "", "user": "monitor"}


def test_all_bracket_styles_equivalent():
    for tok in ("$host", "${host}", "{{ host }}", "{{host}}"):
        assert substitute_str(tok, VARS) == "db01"


def test_whole_match_returns_native_type():
    # a string that is exactly one placeholder keeps the variable's type
    assert substitute_str("${port}", VARS) == 3306
    assert isinstance(substitute_str("{{ port }}", VARS), int)


def test_embedded_is_stringified():
    assert substitute_str("mysql://$host:${port}/db", VARS) == "mysql://db01:3306/db"
    assert substitute_str("user={{ user }}", VARS) == "user=monitor"


def test_default_modifier():
    assert substitute_str("${missing:-fallback}", VARS) == "fallback"
    assert substitute_str("${host:-fallback}", VARS) == "db01"      # present -> used
    assert substitute_str("${empty:-fallback}", VARS) == "fallback"  # empty -> default


def test_required_modifier_raises_with_message():
    assert substitute_str("${host:?needed}", VARS) == "db01"
    with pytest.raises(NTVarError) as e:
        substitute_str("${nope:?you must set nope}", VARS)
    assert "you must set nope" in str(e.value)


def test_unresolved_bare_reference_errors():
    with pytest.raises(NTVarError):
        substitute_str("$nope", VARS)
    with pytest.raises(NTVarError):
        substitute_str("{{ nope }}", VARS)


def test_recursive_over_dict_and_list():
    obj = {"dsn": "$host:${port}", "flags": ["--user=${user}", "--port=${port}"]}
    out = substitute(obj, VARS)
    assert out == {"dsn": "db01:3306", "flags": ["--user=monitor", "--port=3306"]}


def test_merge_scopes_precedence():
    # weakest -> strongest, later wins; None skipped
    merged = merge_scopes({"a": 1, "b": 1}, None, {"b": 2, "c": 2}, {"c": 3})
    assert merged == {"a": 1, "b": 2, "c": 3}
