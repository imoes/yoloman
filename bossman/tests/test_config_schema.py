"""Tests for the per-directive config schema (services/config_schema.py).

Two properties matter, both drawn from real files on docker-test:
  * flatten→inflate must be EXACT — real directive names contain dots and spaces
    ("wifi.scan rand mac address"), so the inverse may never split on ".".
  * types must come from the observed value — the agent's codec renders with Go's
    %v, so a catalog `type: bool`/`int` must not turn "yes" into True or "0177"
    into a number.
"""
from __future__ import annotations

from bossman.services.config_schema import (
    catalog_for_path,
    derive_schema,
    flat_changed,
    flatten,
    inflate,
    load_catalog,
)

# a real ini shape (avahi-daemon.conf), incl. an empty section
INI = {
    "server": {"use-ipv4": "yes", "use-ipv6": "yes", "ratelimit-burst": "1000"},
    "publish": {"publish-hinfo": "no"},
    "rlimits": {},
}
# a real keyvalue shape (chrony.conf) — flat, empty value allowed
KV = {"logdir": "/var/log/chrony", "server": "ntp.example.internal iburst", "rtcsync": ""}
# a real yaml shape (agentic-mcp/config.yaml) — NATIVE types
YAML = {"db": {"path": "/var/lib/x.db"}, "ui": {"enabled": True}, "port": 8080, "tags": ["a", "b"]}


# ------------------------------------------------------------ flatten/inflate --

def test_flatten_nested_ini_and_round_trip_exact():
    flat, index = flatten(INI)
    assert flat["server.use-ipv4"] == "yes"
    assert index["server.use-ipv4"] == ["server", "use-ipv4"]
    assert "rlimits" not in flat                      # empty section contributes no field
    assert inflate(flat, index) == {k: v for k, v in INI.items() if v}   # rlimits dropped, rest exact


def test_flatten_keeps_dots_and_spaces_inside_names():
    # NetworkManager.conf really has this directive
    values = {"device": {"wifi.scan rand mac address": "no"}}
    flat, index = flatten(values)
    assert "device.wifi.scan rand mac address" in flat
    assert index["device.wifi.scan rand mac address"] == ["device", "wifi.scan rand mac address"]
    # the inverse must NOT split on "." — it must reproduce the original nesting
    assert inflate(flat, index) == values


def test_flat_key_collision_keeps_both_exact():
    values = {"a": {"b.c": 1}, "a.b": {"c": 2}}
    flat, index = flatten(values)
    assert len(flat) == 2 and len(index) == 2
    assert inflate(flat, index) == values             # both survive, each exact


def test_inflate_edited_leaf_keeps_everything_else():
    flat, index = flatten(INI)
    flat["server.use-ipv4"] = "no"
    out = inflate(flat, index)
    assert out["server"]["use-ipv4"] == "no"
    assert out["server"]["use-ipv6"] == "yes" and out["publish"] == {"publish-hinfo": "no"}


def test_inflate_unknown_key_uses_section_prefix_then_toplevel():
    # a NEW directive the index doesn't know
    out = inflate({"server.new-opt": "1"}, {}, observed=INI)
    assert out == {"server": {"new-opt": "1"}}        # (b) longest section prefix
    out2 = inflate({"brand.new": "1"}, {}, observed=KV)
    assert out2 == {"brand.new": "1"}                # (c) keyvalue: whole string is the key


def test_inflate_passes_through_already_nested_values():
    out = inflate({"server": {"use-ipv4": "no"}}, {}, observed=INI)
    assert out == {"server": {"use-ipv4": "no"}}      # back-compat for API/MCP callers


def test_flat_changed_is_per_directive():
    after = {**INI, "server": {**INI["server"], "use-ipv4": "no"}}
    assert flat_changed(INI, after) == {"server.use-ipv4": ["yes", "no"]}


# -------------------------------------------------------------- derive_schema --

def test_schema_has_one_field_per_directive_not_a_values_blob():
    schema = derive_schema(KV)
    assert set(schema) == {"logdir", "server", "rtcsync"}
    assert "values" not in schema and "path" not in schema
    assert schema["logdir"] == {"type": "string", "default": "/var/log/chrony", "key_path": ["logdir"]}


def test_schema_bool_catalog_on_string_becomes_lexical_enum():
    # journald.conf Audit: catalog says bool, the file says "yes" → dropdown of the
    # file's own tokens, still a STRING (posting True would write "true")
    schema = derive_schema({"Journal": {"Audit": "yes"}},
                           {"Audit": {"type": "bool", "description": "Kernel auditing."}})
    spec = schema["Journal.Audit"]
    assert spec["type"] == "string" and spec["enum"] == ["yes", "no"]
    assert spec["description"] == "Kernel auditing."


def test_schema_never_widens_string_to_number():
    # login.defs ERASECHAR default 0177 — catalog says int; coercing would write 127
    schema = derive_schema({"ERASECHAR": "0177"}, {"ERASECHAR": {"type": "int", "default": "0177"}})
    assert schema["ERASECHAR"]["type"] == "string" and schema["ERASECHAR"]["default"] == "0177"


def test_schema_enum_prepends_undocumented_current_value():
    schema = derive_schema({"AddressFamily": "custom"},
                           {"AddressFamily": {"values": ["any", "inet", "inet6"]}})
    assert schema["AddressFamily"]["enum"] == ["custom", "any", "inet", "inet6"]


def test_schema_keeps_native_types_from_yaml():
    schema = derive_schema(YAML)
    assert schema["ui.enabled"]["type"] == "bool"
    assert schema["port"]["type"] == "number"
    assert schema["tags"]["type"] == "list"


def test_schema_without_catalog_falls_back_to_string():
    schema = derive_schema({"Whatever": "x"}, {})
    assert schema["Whatever"] == {"type": "string", "default": "x", "key_path": ["Whatever"]}


def test_schema_of_empty_or_missing_values_is_empty():
    assert derive_schema(None) == {} and derive_schema({}) == {}


# --------------------------------------------------------------- catalog ------

def test_catalog_for_path_merges_fullpath_over_basename():
    catalog = {
        "NetworkManager.conf": {"managed": {"type": "bool"}, "plugins": {"type": "list"}},
        "/etc/NetworkManager/NetworkManager.conf": {"managed": {"type": "bool", "description": "specific"}},
    }
    merged = catalog_for_path("/etc/NetworkManager/NetworkManager.conf", catalog)
    assert set(merged) == {"managed", "plugins"}                 # union of both keys
    assert merged["managed"]["description"] == "specific"        # full path wins


def test_catalog_for_path_directory_key():
    # the one real directory-style key in the catalog is a FULL path with a
    # trailing slash, so a drop-in file under it must resolve to it
    catalog = {"/etc/cloud/cloud.cfg.d/": {"opt": {"type": "string"}}}
    assert "opt" in catalog_for_path("/etc/cloud/cloud.cfg.d/90-x.cfg", catalog)


def test_catalog_for_path_unknown_is_empty():
    assert catalog_for_path("/etc/nope.conf", {"other.conf": {"x": {}}}) == {}


def test_load_catalog_without_settings_is_empty():
    assert load_catalog(None) == {}


def test_load_catalog_missing_file_is_empty():
    class S:
        config_directives_path = "/nonexistent/config_directives.json"
    assert load_catalog(S()) == {}
