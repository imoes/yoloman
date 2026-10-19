from bossman.services.schema_defaults import normalize_types


def test_numeric_strings_in_a_number_field_become_numbers():
    s = {"log_level": {"type": "number", "default": "2", "enum": ["0", "1", "2", "3", "4"]},
         "ratio": {"type": "number", "default": "0.5"}, "port": {"type": "integer", "default": "8080"}}
    assert normalize_types(s) == 3
    assert s["log_level"] == {"type": "number", "default": 2, "enum": [0, 1, 2, 3, 4]}
    assert s["ratio"]["default"] == 0.5 and s["port"]["default"] == 8080


def test_a_number_field_holding_a_word_is_a_string_field():
    s = {"threads": {"type": "integer", "default": "auto", "enum": ["auto", 1, 2], "minimum": 1}}
    assert normalize_types(s) == 1
    assert s["threads"] == {"type": "string", "default": "auto", "enum": ["auto", "1", "2"]}


def test_consistent_fields_and_nested_properties():
    s = {"ok": {"type": "integer", "default": 3}, "name": {"type": "string", "default": "2"},
         "main": {"type": "object", "properties": {"ban_time": {"type": "integer", "default": "1900"}}}}
    assert normalize_types(s) == 1
    assert s["ok"]["default"] == 3 and s["name"]["default"] == "2"
    assert s["main"]["properties"]["ban_time"]["default"] == 1900


def test_a_leading_zero_is_text_not_a_number():
    s = {"mode": {"type": "integer", "default": "0644"}}
    normalize_types(s)
    assert s["mode"] == {"type": "string", "default": "0644"}


def test_a_bool_field_holding_config_tokens_keeps_them():
    s = {"rr": {"type": "bool", "default": "1", "enum": ["0", "1"]},
         "pager": {"type": "boolean", "default": "yes", "enum": ["yes", "no"]},
         "real": {"type": "bool", "default": True}}
    assert normalize_types(s) == 2
    assert s["rr"] == {"type": "number", "default": 1, "enum": [0, 1]}
    assert s["pager"] == {"type": "string", "default": "yes", "enum": ["yes", "no"]}
    assert s["real"] == {"type": "bool", "default": True}


def test_a_bool_field_holding_numbers_is_counted():
    s = {"x": {"type": "bool", "default": 0, "enum": [0, 1]}}
    assert normalize_types(s) == 1 and s["x"]["type"] == "number"


def test_container_fields_get_a_container_default_or_lose_it():
    s = {"tls": {"type": "object", "default": "disabled", "properties": {"enabled": {"type": "bool", "default": False}}},
         "opts": {"type": "object", "default": "{}"}, "plugins": {"type": "object", "default": []},
         "nice": {"type": "object", "default": 10}, "ok": {"type": "list", "default": ["a"]}}
    assert normalize_types(s) == 4
    assert "default" not in s["tls"] and s["opts"]["default"] == {} and s["plugins"]["default"] == {}
    assert s["nice"] == {"type": "number", "default": 10} and s["ok"]["default"] == ["a"]
