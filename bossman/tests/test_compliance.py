"""Spec-parsing, version-compare, and host-evaluation tests (services/compliance.py)."""

import pytest

from bossman.services.compliance import _cmp_version, evaluate_host, parse_spec


class _Rule:
    """Stand-in for ComplianceRule (only the fields evaluate_host reads)."""

    def __init__(self, required=None, forbidden=None):
        self.required = required or []
        self.forbidden = forbidden or []


def pkgs(*items):
    return [{"name": n, "version": v} for n, v in items]


def test_parse_spec_bare():
    assert parse_spec("nginx") == ("nginx", None, None)


def test_parse_spec_ops():
    assert parse_spec("openssl>=3.0") == ("openssl", ">=", "3.0")
    assert parse_spec("docker==24.0.7") == ("docker", "==", "24.0.7")
    assert parse_spec("log4j<2.17") == ("log4j", "<", "2.17")
    assert parse_spec("foo=1.2") == ("foo", "==", "1.2")  # '=' normalizes to '=='


def test_parse_spec_invalid():
    with pytest.raises(ValueError):
        parse_spec("")
    with pytest.raises(ValueError):
        parse_spec("nginx>=")  # operator without version


def test_cmp_version_numeric():
    assert _cmp_version("1.24.0", "1.9") > 0   # numeric, not lexical
    assert _cmp_version("3.0", "3.0") == 0
    assert _cmp_version("2.16", "2.17") < 0
    assert _cmp_version("1.0", "1.0.1") < 0


def test_cmp_version_distro_suffix():
    # epoch + debian revision are stripped before comparing.
    assert _cmp_version("1:1.2.3-4ubuntu1", "1.2.3") == 0
    assert _cmp_version("3.0.11-1.el9", "3.0.9") > 0


def test_required_missing():
    v = evaluate_host(pkgs(("bash", "5.1")), _Rule(required=["nginx"]))
    assert len(v) == 1 and v[0]["kind"] == "missing" and v[0]["package"] == "nginx"


def test_required_version_ok_and_bad():
    assert evaluate_host(pkgs(("openssl", "3.0.11")), _Rule(required=["openssl>=3.0"])) == []
    v = evaluate_host(pkgs(("openssl", "1.1.1")), _Rule(required=["openssl>=3.0"]))
    assert len(v) == 1 and v[0]["kind"] == "version"


def test_forbidden_present():
    v = evaluate_host(pkgs(("telnet", "0.17")), _Rule(forbidden=["telnet"]))
    assert len(v) == 1 and v[0]["kind"] == "forbidden"
    # absent forbidden package = compliant
    assert evaluate_host(pkgs(("bash", "5.1")), _Rule(forbidden=["telnet"])) == []


def test_forbidden_version_scoped():
    # forbid only the vulnerable range; a patched version is fine.
    assert evaluate_host(pkgs(("log4j", "2.17.1")), _Rule(forbidden=["log4j<2.17"])) == []
    v = evaluate_host(pkgs(("log4j", "2.14.0")), _Rule(forbidden=["log4j<2.17"]))
    assert len(v) == 1 and v[0]["kind"] == "forbidden"


def test_compliant_returns_empty():
    rule = _Rule(required=["bash", "openssl>=3.0"], forbidden=["telnet"])
    assert evaluate_host(pkgs(("bash", "5.1"), ("openssl", "3.0.11")), rule) == []
