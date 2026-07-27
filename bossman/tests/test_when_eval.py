"""Unit tests for bossman.services.when_eval — pure, no DB, no network.
`when:` is now a real Jinja2 boolean (the pivot to full Ansible semantics),
evaluated in a SandboxedEnvironment (the security boundary). Undefined vars are
lenient (Ansible-style)."""

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
    assert eval_when("some_flag", {}) is False  # undefined is falsy (lenient), not an error


def test_equality():
    assert eval_when("ansible_distribution == 'debian'", {"ansible_distribution": "debian"}) is True
    assert eval_when("ansible_distribution == 'debian'", {"ansible_distribution": "ubuntu"}) is False
    assert eval_when("port == 443", {"port": 443}) is True
    assert eval_when("enabled == true", {"enabled": True}) is True


def test_inequality():
    assert eval_when("ansible_distribution != 'debian'", {"ansible_distribution": "ubuntu"}) is True
    assert eval_when("ansible_distribution != 'debian'", {"ansible_distribution": "debian"}) is False
    assert eval_when("missing != 'x'", {}) is True  # lenient: undefined never equals a literal


def test_full_jinja_now_supported():
    # the whole point of the pivot: real Jinja expressions work (this used to raise)
    assert eval_when("docker.proxy | default('none') == 'none'", {}) is True
    assert eval_when("a == [1, 2]", {"a": [1, 2]}) is True
    assert eval_when("count > 3 and enabled", {"count": 5, "enabled": True}) is True
    assert eval_when("'web' in groups", {"groups": ["web", "db"]}) is True


def test_sandbox_blocks_unsafe_access():
    # the SandboxedEnvironment is the security boundary — an attribute escape to
    # the class hierarchy (the classic sandbox breakout) is neutralised to
    # Undefined, so it can never reach os/subprocess; it evaluates falsy.
    assert eval_when("''.__class__.__mro__", {}) is False
    # an unsafe method *call* (the escape's payload) is rejected outright
    with pytest.raises(WhenError):
        eval_when("''.__class__.__mro__[1].__subclasses__()", {})


def test_syntax_error_raises():
    with pytest.raises(WhenError):
        eval_when("a ==", {"a": 1})
