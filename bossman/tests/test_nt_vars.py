"""Variable substitution: Jinja2 in a sandbox (native-type whole-match, filters, GPO scope merge).

Jinja `{{ }}` is the only templating syntax. A `$var` / `${var:-default}` / `${var:?msg}` shim used to be
rewritten to Jinja here; it is gone, and test_shell_dollar_signs_are_left_alone pins why.
"""

import pytest

from bossman.services.nt_vars import NTVarError, merge_scopes, substitute, substitute_str

VARS = {"host": "db01", "port": 3306, "empty": "", "user": "monitor"}


def test_spacing_inside_the_braces_does_not_matter():
    for tok in ("{{ host }}", "{{host}}", "{{  host  }}"):
        assert substitute_str(tok, VARS) == "db01"


def test_whole_match_returns_native_type():
    # a string that is exactly one placeholder keeps the variable's type
    assert substitute_str("{{ port }}", VARS) == 3306
    assert isinstance(substitute_str("{{ port }}", VARS), int)


def test_embedded_is_stringified():
    assert substitute_str("mysql://{{ host }}:{{ port }}/db", VARS) == "mysql://db01:3306/db"
    assert substitute_str("user={{ user }}", VARS) == "user=monitor"


def test_default_filter():
    # `| default(x, true)` is the Ansible way to say "also fall back when the value is empty".
    assert substitute_str("{{ missing | default('fallback', true) }}", VARS) == "fallback"
    assert substitute_str("{{ host | default('fallback', true) }}", VARS) == "db01"      # present -> used
    assert substitute_str("{{ empty | default('fallback', true) }}", VARS) == "fallback"  # empty -> default


def test_mandatory_filter_raises_with_message():
    assert substitute_str("{{ host | mandatory('needed') }}", VARS) == "db01"
    with pytest.raises(NTVarError) as e:
        substitute_str("{{ nope | mandatory('you must set nope') }}", VARS)
    assert "you must set nope" in str(e.value)


def test_unresolved_reference_errors():
    # StrictUndefined: an unresolved variable is an error, never a silent blank.
    with pytest.raises(NTVarError):
        substitute_str("{{ nope }}", VARS)
    with pytest.raises(NTVarError):
        substitute_str("prefix-{{ nope }}", VARS)


def test_shell_dollar_signs_are_left_alone():
    """The reason the `$var` shim had to go: it rewrote `$word` inside EVERY string, so ordinary shell
    arguments broke. `echo $HOME` raised "'HOME' is undefined", and `awk "{print $2}"` was silently
    corrupted to `awk "{print 2}"` — a wrong command sent to a host with no error anywhere. Shell arguments
    are the most common thing in a runbook, so a templating engine must not touch their `$`."""
    for text in ('echo $HOME', 'awk "{print $2}"', 'PATH=$PATH:/opt/bin', 'test -n "$1"'):
        assert substitute_str(text, VARS) == text


def test_recursive_over_dict_and_list():
    obj = {"dsn": "{{ host }}:{{ port }}", "flags": ["--user={{ user }}", "--port={{ port }}"]}
    out = substitute(obj, VARS)
    assert out == {"dsn": "db01:3306", "flags": ["--user=monitor", "--port=3306"]}


def test_merge_scopes_precedence():
    # weakest -> strongest, later wins; None skipped
    merged = merge_scopes({"a": 1, "b": 1}, None, {"b": 2, "c": 2}, {"c": 3})
    assert merged == {"a": 1, "b": 2, "c": 3}


def test_dotted_access_into_nested_inventory():
    """The `inventory` magic var is reached via dotted paths."""
    v = {
        "inventory": {
            "product": {"serial": "ABC123"},
            "cpu": {"model": "EPYC 7302", "count": 32},
            "memory": {"total_mb": 64000},
        },
        "region": "eu",
    }
    # whole-match preserves native type
    assert substitute_str("{{ inventory.cpu.count }}", v) == 32
    assert substitute_str("{{ inventory.product.serial }}", v) == "ABC123"
    # embedded stringifies
    assert substitute_str("cpu {{ inventory.cpu.model }} in {{ region }}", v) == "cpu EPYC 7302 in eu"
    # a missing INTERMEDIATE (`gpu`) must chain into an Undefined the default filter can handle, not blow up
    assert substitute_str("{{ inventory.gpu.model | default('none', true) }}", v) == "none"
    # plain (non-dotted) vars still resolve
    assert substitute_str("{{ region }}", v) == "eu"
    # recursion into args
    assert substitute({"m": "{{ inventory.memory.total_mb }}"}, v) == {"m": 64000}
