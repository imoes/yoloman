"""Endpoint-parsing and status tests (services/cert_inventory.py)."""

from bossman.services.cert_inventory import compute_status, parse_endpoint


def test_parse_endpoint_url():
    assert parse_endpoint("https://example.com/path") == ("example.com", 443)
    assert parse_endpoint("https://example.com:8443/") == ("example.com", 8443)


def test_parse_endpoint_hostport():
    assert parse_endpoint("mail.example.com:993") == ("mail.example.com", 993)


def test_parse_endpoint_bare_host():
    assert parse_endpoint("example.com") == ("example.com", 443)


def test_parse_endpoint_whitespace():
    assert parse_endpoint("  example.com:465  ") == ("example.com", 465)


def test_compute_status():
    assert compute_status(None, 30, 7) == "unknown"
    assert compute_status(-1, 30, 7) == "expired"
    assert compute_status(0, 30, 7) == "critical"
    assert compute_status(7, 30, 7) == "critical"
    assert compute_status(8, 30, 7) == "warning"
    assert compute_status(30, 30, 7) == "warning"
    assert compute_status(31, 30, 7) == "ok"
    assert compute_status(365, 30, 7) == "ok"
