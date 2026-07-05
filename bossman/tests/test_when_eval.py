"""Unit tests for bossman.services.when_eval — pure, no DB, no network.
Covers exactly the grammar plan_engine.py's `when:` support promises, and
nothing more (this is deliberately not a Jinja2 evaluator)."""

import pytest

from bossman.services.when_eval import WhenError, eval_when


def test_is_defined_true_when_path_present():
    assert eval_when("docker.proxy", {"docker": {"proxy": "http://proxy:3128"}}) is True


def test_is_defined_true_explicit():
    assert eval_when("docker.proxy is defined", {"docker": {"proxy": "x"}}) is True


def test_is_defined_false_when_path_missing():
    assert eval_when("docker.proxy is defined", {"docker": {}}) is False
    assert eval_when("docker.proxy is defined", {}) is False


def test_is_not_defined():
    assert eval_when("docker.proxy is not defined", {}) is True
    assert eval_when("docker.proxy is not defined", {"docker": {"proxy": "x"}}) is False


def test_not_prefix_negates():
    assert eval_when("not docker.proxy is defined", {}) is True
    assert eval_when("not _containerd_dir.data.exists", {"_containerd_dir": {"data": {"exists": False}}}) is True
    assert eval_when("not _containerd_dir.data.exists", {"_containerd_dir": {"data": {"exists": True}}}) is False


def test_registered_result_nested_path():
    context = {"_daemon_json_stat": {"data": {"exists": True, "path": "/etc/docker/daemon.json"}}}
    assert eval_when("_daemon_json_stat.data.exists", context) is True


def test_bare_path_truthy_check():
    assert eval_when("some_flag", {"some_flag": True}) is True
    assert eval_when("some_flag", {"some_flag": False}) is False
    assert eval_when("some_flag", {}) is False  # undefined is falsy, not an error


def test_equality():
    assert eval_when("ansible_distribution == 'debian'", {"ansible_distribution": "debian"}) is True
    assert eval_when("ansible_distribution == 'debian'", {"ansible_distribution": "ubuntu"}) is False
    assert eval_when("port == 443", {"port": 443}) is True
    assert eval_when("enabled == true", {"enabled": True}) is True


def test_inequality():
    assert eval_when("ansible_distribution != 'debian'", {"ansible_distribution": "ubuntu"}) is True
    assert eval_when("ansible_distribution != 'debian'", {"ansible_distribution": "debian"}) is False
    assert eval_when("missing != 'x'", {}) is True  # undefined never equals a literal


def test_unsupported_expression_raises():
    with pytest.raises(WhenError, match="unsupported when-expression"):
        eval_when("docker.proxy | default('none')", {})


def test_unparseable_literal_raises():
    with pytest.raises(WhenError, match="cannot parse literal"):
        eval_when("a == [1, 2]", {"a": "x"})
