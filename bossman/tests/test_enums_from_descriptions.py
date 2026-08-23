"""Reading a value set out of a field's own description — every gate here is a measured mistake.

The enum gap was being attacked with LLM calls at a measured yield of +2 fields per 36 templates, while the
un-enumerated fields carried their value sets in their own descriptions, unparsed:

    "Logging level: one of 'debug', 'info', 'warn', 'error'"

This is that extraction. It accepts 422 fields across 323 templates and refuses 25 481, and the refusals are
the interesting half: a WRONG dropdown is worse than a text box, because the operator cannot type the value
the software wants and the template write path is whole-file.
"""

import pytest

from bossman.tools.enums_from_descriptions import apply_to, extract


@pytest.mark.parametrize("description, expected", [
    # The introducing phrases, as they appear in the corpus.
    ("Logging level: one of 'debug', 'info', 'warn', 'error'", ["debug", "info", "warn", "error"]),
    ("Verbosity level for server logs. Options: debug, info, notice, warning",
     ["debug", "info", "notice", "warning"]),
    ("Output format for sensor readings. Valid values: plain, json, csv", ["plain", "json", "csv"]),
    ("Verbosity of logging output. Choose from 'debug', 'info', 'warn'.", ["debug", "info", "warn"]),
    ("Execute CustomData after provisioning. Supported values are y or n.", ["y", "n"]),
    # No introducing phrase at all — the quotes are the author saying "these are literals".
    ("Detection method: 'threshold' or 'stddev'. Must be one of these two values.",
     ["threshold", "stddev"]),
    ("Encryption algorithm to use ('none', 'aes', 'twofish').", ["none", "aes", "twofish"]),
])
def test_a_stated_value_set_is_read(description, expected):
    assert extract(description)[0] == expected


@pytest.mark.parametrize("description, expected", [
    # THE TRUNCATION BUG. "'a', 'b', or 'c'" has a comma AND an "or" before the last item; a separator
    # pattern accepting only one of the two stops at 'b' and silently drops 'c'. Measured on five fields in
    # one sample — garagemq lost 'file', osmo_sgsn lost 'require', freefilesync lost 'retry'.
    ("Log destination: 'stdout', 'stderr', or 'file'.", ["stdout", "stderr", "file"]),
    ("Behavior on error: 'continue', 'abort', or 'retry'.", ["continue", "abort", "retry"]),
    ("Link type: 'ether', 'bond', 'vlan', and 'bridge'.", ["ether", "bond", "vlan", "bridge"]),
    ("Where to send logs: 'syslog', 'file', or 'stdout'.", ["syslog", "file", "stdout"]),
])
def test_the_last_item_is_not_dropped(description, expected):
    """A truncated dropdown is worse than none: it removes a legal value and looks authoritative doing it."""
    assert extract(description)[0] == expected


@pytest.mark.parametrize("description", [
    # AN EXAMPLE IS NOT AN ENUMERATION — the gate that matters most, and it cut acceptance from 789 to 422.
    "Preferred architecture override (e.g., 'amd64', 'arm64'). If omitted, auto-detected.",
    "Device class filter (e.g., 'backlight', 'leds')",
    "Default language, for example 'en_US.UTF-8' or 'de_DE'.",
    "Cache backend, such as 'redis' or 'memcached'.",
    "Common values: 'hmac-sha256', 'hmac-sha512'",
    "Typically 'always' or 'on-failure'.",
])
def test_an_example_or_hedged_list_is_refused(description):
    values, reason = extract(description)
    assert values == [], f"{description!r} was read as an allowed set"
    assert "example" in reason or "common" in reason


@pytest.mark.parametrize("description, marker", [
    # Each of these was accepted by an earlier version of the extractor.
    ("Additional command-line options to pass to acpid", "value list"),
    ("Version of DPkg::Tools::Options for adequate.", "value list"),
    ("Comma-separated list of default option=value pairs for accounts", "value list"),
    ("Compose file version (e.g., \"3.8\"). Must be one of the officially supported versions.", ""),
    ("Error correction redundancy. Allowed values depend on the method.", ""),
    ("Network interface to bind to, either as host:port or a Unix socket path", ""),
])
def test_prose_is_refused(description, marker):
    values, reason = extract(description)
    assert values == [], f"{description!r} was read as a value list, giving {values}"
    assert reason, "a refusal without a reason is the silence this record exists to end"


def test_a_list_of_other_FIELDS_is_not_a_list_of_values():
    """"Only one of dns_manual or dns_hook should be set" is a sentence about two fields of this schema."""
    # Quoted, so both tokens ARE value-shaped and the list survives to the gate — which is the only way to
    # test the gate itself. The unquoted form in the corpus ("Only one of dns_manual or dns_hook should be
    # set") is refused earlier, because "dns_hook should be set" is not a value token.
    values, reason = extract("Set one of 'dns_manual' or 'dns_hook'.",
                             {"dns_manual", "dns_hook", "domains"})
    assert values == []
    assert "other fields" in reason
    # Without the schema's field names there is nothing to compare against, and it reads as a value list.
    assert extract("Set one of 'dns_manual' or 'dns_hook'.")[0] == ["dns_manual", "dns_hook"]


def test_the_numeric_form_yields_the_NUMBERS():
    """"0=error, 1=warn" — the number is what gets written to the file; the word explains it and belongs in
    the description that already carries it. Putting "1 (error)" in the dropdown would write that string."""
    values, reason = extract("Logging verbosity: 0=error, 1=warn, 2=info, 3=debug.")
    assert values == ["0", "1", "2", "3"]
    assert "numeric" in reason


def test_a_parenthetical_explains_a_value_and_is_not_part_of_it():
    values, _ = extract("Output format. Valid values: plain (human-readable), json (structured), csv")
    assert values == ["plain", "json", "csv"]


def test_no_description_is_a_named_refusal():
    values, reason = extract("")
    assert values == [] and reason == "no description"


# --------------------------------------------------------------------------- applying it to a schema

def test_only_untyped_free_text_string_fields_are_touched():
    schema = {
        "log_level": {"type": "string", "description": "Level: one of 'debug', 'info'"},
        "already": {"type": "string", "enum": ["a", "b"], "description": "Options: c, d"},
        "a_number": {"type": "int", "description": "Options: 1, 2"},
    }
    out, decisions = apply_to(schema)
    assert out["log_level"]["enum"] == ["debug", "info"]
    assert out["already"]["enum"] == ["a", "b"], "an existing enum must not be overwritten"
    assert "enum" not in out["a_number"], "a non-string field is not a dropdown candidate"
    # A field that was never a candidate is not reported as a refusal either — only string fields are judged.
    assert {d["field"] for d in decisions} == {"log_level"}


def test_a_default_outside_the_extracted_set_refuses():
    """One of the two is wrong and this pass cannot tell which. Offering the dropdown would silently change
    the file's current setting on the first Apply — the same rule the LLM stage applies."""
    schema = {"mode": {"type": "string", "default": "turbo",
                       "description": "Mode: one of 'fast', 'slow'"}}
    out, decisions = apply_to(schema)
    assert "enum" not in out["mode"]
    assert decisions[0]["accepted"] is False
    assert "default" in decisions[0]["reason"]
    # The values it DID find travel with the refusal — that is what makes the decision reviewable.
    assert decisions[0]["values"] == ["fast", "slow"]


def test_a_default_inside_the_set_is_accepted():
    schema = {"mode": {"type": "string", "default": "fast", "description": "Mode: one of 'fast', 'slow'"}}
    out, _ = apply_to(schema)
    assert out["mode"]["enum"] == ["fast", "slow"]


def test_the_wrapped_properties_shape_is_handled():
    schema = {"properties": {"fmt": {"type": "string", "description": "Valid values: json, yaml"}}}
    out, _ = apply_to(schema)
    assert out["properties"]["fmt"]["enum"] == ["json", "yaml"]


def test_every_candidate_gets_a_decision_recorded():
    """Accepted or refused, each string field is accounted for — "why is this still a text box" has to have
    an answer for the fields this pass declined too."""
    schema = {
        "good": {"type": "string", "description": "one of 'a', 'b'"},
        "prose": {"type": "string", "description": "Some free text with no list."},
        "nodesc": {"type": "string"},
    }
    _, decisions = apply_to(schema)
    assert {d["field"] for d in decisions} == {"good", "prose", "nodesc"}
    assert all(d.get("reason") for d in decisions)
