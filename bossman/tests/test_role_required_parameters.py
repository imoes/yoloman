"""The preview names EVERY missing required role parameter (values only the site has) before anything deploys."""

from types import SimpleNamespace

import pytest
from fastapi import HTTPException

from bossman.api.role_deployments import _validate_parameters

SCHEMA = {"tunnel_ip": {"type": "string", "required": True}, "topdomain": {"type": "string", "required": True},
          "password": {"type": "string", "required": True}, "extra_args": {"type": "string"},
          "_dest": {"type": "string", "hidden": True}}


def version(defaults=None):
    return SimpleNamespace(parameter_schema=SCHEMA, default_parameters=defaults or {})


def test_all_missing_values_are_named_at_once():
    with pytest.raises(HTTPException) as err:
        _validate_parameters(version(), {})
    assert err.value.status_code == 422
    assert err.value.detail == "required role parameters 'password', 'topdomain', 'tunnel_ip' are missing"


def test_one_missing_value_reads_singular():
    with pytest.raises(HTTPException) as err:
        _validate_parameters(version(), {"tunnel_ip": "10.53.0.1/27", "topdomain": "t.example.test"})
    assert err.value.detail == "required role parameter 'password' is missing"


def test_complete_values_pass():
    _validate_parameters(version(), {"tunnel_ip": "10.53.0.1/27", "topdomain": "t.example.test", "password": "x"})


def test_an_empty_list_is_missing():
    v = SimpleNamespace(parameter_schema={"subnets": {"type": "list", "required": True}}, default_parameters={})
    with pytest.raises(HTTPException) as err:
        _validate_parameters(v, {"subnets": []})
    assert err.value.detail == "required role parameter 'subnets' is missing"
