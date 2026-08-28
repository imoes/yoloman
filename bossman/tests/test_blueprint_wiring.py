"""Offline tests for the blueprint connector resolver — the full-field
requires↔provides wiring, secret marking, and plausibility (no DB/LLM)."""
from __future__ import annotations

from bossman.config import Settings
from bossman.services import blueprint as bp


def _wordpress_services():
    return [
        {"name": "db", "kind": "docker", "environment": {
            "MARIADB_DATABASE": "wordpress", "MARIADB_USER": "wp", "MARIADB_PASSWORD": "wp-secret"},
         "values": {}, "ports": ["3306"], "depends_on": [],
         "provides": [{"capability": "database", "backend": "mariadb", "default_port": 3306,
                       "field_sources": {
                           "host": {"from": "address"}, "port": {"from": "port"},
                           "name": {"from": "env", "key": "MARIADB_DATABASE"},
                           "user": {"from": "env", "key": "MARIADB_USER"},
                           "password": {"from": "env", "key": "MARIADB_PASSWORD", "secret": True}}}],
         "requires": []},
        {"name": "wordpress", "kind": "docker", "environment": {}, "values": {}, "ports": ["80"],
         "depends_on": ["db"], "provides": [],
         "requires": [{"capability": "database", "backends": ["mysql", "mariadb"],
                       "field_targets": {"host": "WORDPRESS_DB_HOST", "port": "WORDPRESS_DB_PORT",
                                         "name": "WORDPRESS_DB_NAME", "user": "WORDPRESS_DB_USER",
                                         "password": "WORDPRESS_DB_PASSWORD"}}]},
    ]


def test_connector_wires_all_connection_fields():
    s = Settings()
    wiring, unresolved = bp.resolve_wiring(s, _wordpress_services())
    assert unresolved == []
    assert len(wiring) == 1
    w = wiring[0]
    assert w["provider"] == "db" and w["backend"] == "mariadb"
    # every canonical field (host/port/name/user/password) is mapped, not just host/port
    assert w["set"]["WORDPRESS_DB_HOST"] == "db"
    assert w["set"]["WORDPRESS_DB_PORT"] == 3306
    assert w["set"]["WORDPRESS_DB_NAME"] == "wordpress"
    assert w["set"]["WORDPRESS_DB_USER"] == "wp"
    assert w["set"]["WORDPRESS_DB_PASSWORD"] == "wp-secret"
    assert w["secret_fields"] == ["WORDPRESS_DB_PASSWORD"]
    assert w["missing_fields"] == []


def test_plausibility_flags_unmet_requirement():
    s = Settings()
    services = [{"name": "app", "kind": "docker", "environment": {}, "values": {}, "ports": [],
                 "depends_on": [], "provides": [],
                 "requires": [{"capability": "database", "backends": ["postgresql"],
                               "field_targets": {"host": "DB_HOST"}}]}]
    pl = bp.plausibility(s, services)
    assert pl["ok"] is False
    assert any(p["severity"] == "error" and p["consumer"] == "app" for p in pl["problems"])


def test_missing_field_is_a_warning_not_an_error():
    s = Settings()
    services = [
        {"name": "db", "kind": "docker", "environment": {}, "values": {}, "ports": [], "depends_on": [],
         "provides": [{"capability": "database", "backend": "mariadb", "default_port": 3306}],  # no field_sources for creds
         "requires": []},
        {"name": "app", "kind": "docker", "environment": {}, "values": {}, "ports": [], "depends_on": ["db"],
         "provides": [],
         "requires": [{"capability": "database", "backends": ["mariadb"],
                       "field_targets": {"host": "H", "user": "U", "password": "P"}}]},
    ]
    pl = bp.plausibility(s, services)
    assert pl["ok"] is True  # host resolves → no error
    assert any(p["severity"] == "warning" for p in pl["problems"])  # user/password missing → warning
