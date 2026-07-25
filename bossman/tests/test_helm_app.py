"""Unit tests for the Helm values → flat schema/values derivation (the typed
FORM the k8s deploy UI renders instead of a raw values.yaml textarea) and the
inverse flat-values → YAML conversion used on render/deploy."""
from __future__ import annotations

import yaml

from bossman.services.helm_app import derive_schema, flat_to_yaml

SAMPLE = """
replicaCount: 1
image:
  repository: nginx
  tag: "1.27"
  pullPolicy: IfNotPresent
service:
  type: ClusterIP
  port: 80
ingress:
  enabled: false
  hosts:
    - host: chart-example.local
      paths: []
resources: {}
extraArgs:
  - --foo
  - --bar
"""


def test_derive_schema_flattens_scalars_and_infers_types():
    schema, flat = derive_schema(yaml.safe_load(SAMPLE))
    # nested dicts become dotted keys
    assert "image.repository" in schema
    assert "service.port" in schema
    # types inferred from the value
    assert schema["replicaCount"]["type"] == "number"
    assert schema["service.port"]["type"] == "number"
    assert schema["ingress.enabled"]["type"] == "bool"
    assert schema["image.repository"]["type"] == "string"
    # scalar list becomes a list field
    assert schema["extraArgs"]["type"] == "list"
    # the chart's own defaults are carried through
    assert flat["image.repository"] == "nginx"
    assert flat["service.port"] == 80
    assert flat["ingress.enabled"] is False


def test_derive_schema_skips_complex_structures():
    schema, _ = derive_schema(yaml.safe_load(SAMPLE))
    # list-of-objects (ingress.hosts) and empty maps (resources) have no flat
    # form control — they stay editable via the YAML view, not the form.
    assert not any(k.startswith("ingress.hosts") for k in schema)
    assert "resources" not in schema


def test_flat_to_yaml_round_trips_into_nested_yaml():
    _, flat = derive_schema(yaml.safe_load(SAMPLE))
    flat["replicaCount"] = 2  # a form edit
    out = yaml.safe_load(flat_to_yaml(flat))
    assert out["replicaCount"] == 2
    assert out["image"]["repository"] == "nginx"
    assert out["service"]["port"] == 80
    assert out["ingress"]["enabled"] is False
    assert out["extraArgs"] == ["--foo", "--bar"]


def test_flat_to_yaml_empty():
    assert flat_to_yaml({}) == ""


def test_derive_schema_non_dict_is_empty():
    assert derive_schema(None) == ({}, {})
    assert derive_schema([1, 2, 3]) == ({}, {})
