"""Rule conditions — the six fields, against Checkmk's own semantics.

Each case encodes a rule from cmk/utils/rulesets/ruleset_matcher.py. The subtle ones are
called out: "not" means AND NOT, an object with no labels is a special case, and a plain
host name must not match by prefix.
"""

from bossman.services.rule_conditions import (
    MatchContext,
    matches,
    matches_labels,
    matches_tag_condition,
)


def _ctx(**kw):
    return MatchContext(**kw)


# --- no condition -----------------------------------------------------------


def test_absent_condition_matches_everything():
    """Every pre-existing rule has no conditions and must keep applying."""
    assert matches(None, _ctx(host_name="h")) is True
    assert matches({}, _ctx(host_name="h")) is True


# --- host_name / service_description ---------------------------------------


def test_exact_host_name_is_not_a_prefix_match():
    """"web" must not match "web-staging" — names are escaped and anchored."""
    assert matches({"host_name": ["web"]}, _ctx(host_name="web"))
    assert not matches({"host_name": ["web"]}, _ctx(host_name="web-staging"))


def test_regex_condition():
    cond = {"host_name": [{"$regex": "^vpp02"}]}
    assert matches(cond, _ctx(host_name="vpp0221.example.com"))
    assert not matches(cond, _ctx(host_name="docker-test"))


def test_host_list_is_an_or():
    cond = {"host_name": ["a", "b"]}
    assert matches(cond, _ctx(host_name="b"))
    assert not matches(cond, _ctx(host_name="c"))


def test_nor_negates_the_whole_list():
    cond = {"host_name": {"$nor": ["a", {"$regex": "^test"}]}}
    assert matches(cond, _ctx(host_name="prod1"))
    assert not matches(cond, _ctx(host_name="a"))
    assert not matches(cond, _ctx(host_name="test-7"))


def test_service_description_only_applies_when_a_service_is_in_hand():
    """A host-level evaluation must not drop a rule that names a service.

    Otherwise a rule scoped to "Disk /var" would vanish from the host entirely instead of
    applying to that one service.
    """
    cond = {"service_description": [{"$regex": "^Disk"}]}
    assert matches(cond, _ctx(host_name="h"))  # no service given -> not judged
    assert matches(cond, _ctx(host_name="h", service_name="Disk /var"))
    assert not matches(cond, _ctx(host_name="h", service_name="Memory"))


# --- host_folder ------------------------------------------------------------


def test_host_folder_matches_at_or_below():
    cond = {"host_folder": "/prod"}
    assert matches(cond, _ctx(ou_paths=["/", "/prod"]))
    assert matches(cond, _ctx(ou_paths=["/", "/prod", "/prod/db"]))
    assert not matches(cond, _ctx(ou_paths=["/", "/staging"]))


def test_host_folder_is_not_a_string_prefix():
    """"/prod" must not match "/production" — the boundary is a path separator."""
    assert not matches({"host_folder": "/prod"}, _ctx(ou_paths=["/", "/production"]))


# --- host_tags --------------------------------------------------------------


def test_tag_equality_and_operators():
    tags = {"env": "prod", "role": "db"}
    assert matches_tag_condition("env", "prod", tags)
    assert not matches_tag_condition("env", "stage", tags)
    assert matches_tag_condition("env", {"$ne": "stage"}, tags)
    assert not matches_tag_condition("env", {"$ne": "prod"}, tags)
    assert matches_tag_condition("env", {"$or": ["prod", "stage"]}, tags)
    assert not matches_tag_condition("env", {"$nor": ["prod"]}, tags)
    assert matches_tag_condition("env", {"$nor": ["stage"]}, tags)


def test_missing_tag_group():
    assert not matches_tag_condition("env", "prod", {})
    # $ne against an absent tag is TRUE — the host does not have that value.
    assert matches_tag_condition("env", {"$ne": "prod"}, {})


def test_unknown_operator_does_not_match_everything():
    assert not matches_tag_condition("env", {"$bogus": "x"}, {"env": "prod"})


def test_tags_are_anded_across_groups():
    cond = {"host_tags": {"env": "prod", "role": "db"}}
    assert matches(cond, _ctx(host_tags={"env": "prod", "role": "db"}))
    assert not matches(cond, _ctx(host_tags={"env": "prod", "role": "web"}))


# --- label groups (the and/or/not grammar) ---------------------------------


def test_label_and_within_a_group():
    labels = {"os": "linux", "tier": "gold"}
    assert matches_labels(labels, [["and", [["and", "os:linux"], ["and", "tier:gold"]]]])
    assert not matches_labels(labels, [["and", [["and", "os:linux"], ["and", "tier:silver"]]]])


def test_label_or_within_a_group():
    labels = {"tier": "silver"}
    assert matches_labels(labels, [["and", [["and", "tier:gold"], ["or", "tier:silver"]]]])


def test_label_not_means_and_not():
    """Checkmk's _and_or_not_group_match: "not" is AND NOT, not a standalone negation."""
    labels = {"os": "linux", "tier": "gold"}
    assert matches_labels(labels, [["and", [["and", "os:linux"], ["not", "tier:silver"]]]])
    assert not matches_labels(labels, [["and", [["and", "os:linux"], ["not", "tier:gold"]]]])


def test_groups_combine_with_or():
    labels = {"tier": "bronze"}
    groups = [
        ["and", [["and", "tier:gold"]]],
        ["or", [["and", "tier:bronze"]]],
    ]
    assert matches_labels(labels, groups)


def test_object_without_labels():
    """Checkmk: a label group matches an unlabelled object only if it has no "and"."""
    assert not matches_labels({}, [["and", [["and", "os:linux"]]]])
    assert matches_labels({}, [["and", [["not", "os:linux"]]]])


def test_empty_label_entries_are_skipped():
    assert matches_labels({"a": "b"}, [["and", [["and", ""]]]])


def test_service_labels_only_when_a_service_is_given():
    cond = {"service_label_groups": [["and", [["and", "tier:gold"]]]]}
    assert matches(cond, _ctx(host_name="h"))  # host-level: not judged
    assert matches(cond, _ctx(host_name="h", service_name="s", service_labels={"tier": "gold"}))
    assert not matches(cond, _ctx(host_name="h", service_name="s", service_labels={"tier": "tin"}))


# --- combinations ----------------------------------------------------------


def test_all_six_fields_are_anded():
    cond = {
        "host_name": [{"$regex": "^vpp"}],
        "host_folder": "/prod",
        "host_tags": {"env": "prod"},
        "host_label_groups": [["and", [["and", "os:linux"]]]],
        "service_description": [{"$regex": "^Disk"}],
        "service_label_groups": [["and", [["and", "tier:gold"]]]],
    }
    ok = _ctx(
        host_name="vpp0221", ou_paths=["/", "/prod"], host_tags={"env": "prod"},
        host_labels={"os": "linux"}, service_name="Disk /var", service_labels={"tier": "gold"},
    )
    assert matches(cond, ok)
    # flip exactly one field at a time
    import dataclasses

    assert not matches(cond, dataclasses.replace(ok, host_name="docker-test"))
    assert not matches(cond, dataclasses.replace(ok, ou_paths=["/", "/staging"]))
    assert not matches(cond, dataclasses.replace(ok, host_tags={"env": "test"}))
    assert not matches(cond, dataclasses.replace(ok, host_labels={"os": "windows"}))
    assert not matches(cond, dataclasses.replace(ok, service_name="Memory"))
    assert not matches(cond, dataclasses.replace(ok, service_labels={"tier": "tin"}))


def test_json_round_trip_shape():
    """A JSON round trip turns Checkmk's tuples into lists; both must work."""
    import json

    cond = {"host_label_groups": [["and", [["and", "os:linux"]]]]}
    assert matches(json.loads(json.dumps(cond)), _ctx(host_labels={"os": "linux"}))
