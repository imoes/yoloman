"""An example is not an enumeration — marked, not deleted.

The description extractor refuses to BUILD an enum from "(e.g., 'amd64', 'arm64')". The LLM enum stage has no
such gate and ran first, so 497 fields carry a closed menu built from an open set:

    alien/target_arch     enum ['all','source','any']    desc "e.g., 'amd64', 'i386', 'all'"
    apcupsd_cgi/syslog    enum ['daemon','user']         desc "Common values: 'daemon', 'local0'-'local7'"

A syslog dropdown without local0-local7 does not look thin, it makes the needed value untypable — and the
template write path is whole-file. Deleting the sets would be wrong too: several are correct sets that happen
to be introduced with a hedge. So they are marked `enum_open` and rendered as suggestions.
"""

import pytest

from bossman.tools.mark_open_enums import _dedupe, hedged


@pytest.mark.parametrize("description, values", [
    ("Hardware revision string (e.g., '2101,2102')", ["2101", "2102"]),
    ("Force the architecture (e.g., 'amd64', 'i386', 'all').", ["all", "source", "any"]),
    ("Syslog facility. Common values: 'daemon', 'local0'-'local7'.", ["daemon", "user"]),
    ("Fact caching method. Common options: 'jsonfile', 'memory', 'redis'.", ["jsonfile", "memory"]),
    ("Pager program (e.g., 'less -r').", ["less -r", "more"]),
    ("Daemon operating mode — typically 'daemon' or 'standalone'.", ["daemon", "primary"]),
])
def test_a_hedged_set_is_recognised(description, values):
    assert hedged(description, values), f"{description!r} was treated as a closed set"


@pytest.mark.parametrize("description, values", [
    # A closed statement: no hedge at all.
    ("Verbosity. Options: debug, info, warning, error.", ["debug", "info", "warning", "error"]),
    ("ACL tag type. Must be one of 'user', 'group', 'mask', 'other'.", ["user", "group"]),
    # THE HEDGE MUST BE ABOUT THESE VALUES. A description that lists its set and then says "see e.g. the
    # manual" has not opened anything — locality is what stops the marker from reaching backwards.
    ("Options: debug, info. For more detail see e.g. the upstream documentation about logging levels.",
     ["debug", "info"]),
])
def test_a_closed_set_is_left_alone(description, values):
    assert hedged(description, values) == ""


def test_an_empty_or_absent_description_opens_nothing():
    assert hedged("", ["a", "b"]) == ""
    assert hedged("e.g. anything", []) == ""


@pytest.mark.parametrize("values, expected", [
    # `acl/permissions` really carried r-- twice: a menu with two identical entries.
    (["r--", "r--", "rw-"], ["r--", "rw-"]),
    (["UTC", "CET", "UTC"], ["UTC", "CET"]),
    # First occurrence wins and the order is preserved — the order is what the author chose.
    (["z", "a", "z", "b"], ["z", "a", "b"]),
    (["a", "b"], ["a", "b"]),
    # Numbers and their string forms are the same OPTION as far as a menu is concerned.
    ([1, "1", 2], [1, 2]),
])
def test_duplicates_are_removed_keeping_order(values, expected):
    assert _dedupe(values) == expected
