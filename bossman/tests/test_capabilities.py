"""Pure-logic tests for the Lego capability matcher (services/capabilities.py) — the deterministic
inventory join + matching, no LLM and (here) no DB. DB-backed reconcile/find_providers are covered in
test_capabilities_db.py against a real session.
"""
from __future__ import annotations

import json
from pathlib import Path

from bossman.config import Settings
from bossman.services import capabilities as C


_REPO_VOCAB = Path(__file__).resolve().parents[2] / "configs" / "capability_vocabulary.json"


def _mk_configs(tmp: Path) -> Settings:
    """A throwaway configs/ tree: package_catalog.json + the real capability_vocabulary.json + a couple of
    capabilities.json sidecars."""
    ct = tmp / "config_templates"
    ct.mkdir(parents=True)
    (tmp / "capability_vocabulary.json").write_text(_REPO_VOCAB.read_text())  # real vocab, real aliases
    (tmp / "package_catalog.json").write_text(json.dumps({
        "postgresql": {"template": "postgresql", "label": "PostgreSQL",
                       "families": {"debian": {"packages": ["postgresql"], "config_path": "/etc/postgresql/main.conf"}}},
        "roundcube": {"template": "roundcube", "label": "Roundcube",
                      "families": {"debian": {"packages": ["roundcube-core"], "config_path": "/etc/roundcube/config.inc.php"}}},
        "nfs": {"template": "exports", "label": "NFS server",
                "families": {"debian": {"packages": ["nfs-kernel-server"], "config_path": "/etc/exports"}}},
    }))
    (ct / "postgresql").mkdir()
    (ct / "postgresql" / "capabilities.json").write_text(json.dumps({
        "provides": [{"capability": "database", "backend": "postgresql", "port_field": "port", "default_port": 5432}],
        "requires": [], "peer_injection": [], "confidence": "high"}))
    (ct / "roundcube").mkdir()
    (ct / "roundcube" / "capabilities.json").write_text(json.dumps({
        "provides": [],
        "requires": [{"capability": "database", "backends": ["mysql", "mariadb"], "backend_field": "db_host",
                      "fields": {"host": "db_host", "port": "db_port", "user": "db_user", "password": "db_pass"}}],
        "peer_injection": [], "confidence": "high"}))
    (ct / "exports").mkdir()
    (ct / "exports" / "capabilities.json").write_text(json.dumps({
        "provides": [{"capability": "nfs", "backend": "nfs", "default_port": None}],
        "requires": [],
        "peer_injection": [{"capability": "nfs", "field": "exports", "kind": "client_list", "items_style": "items_fields"}],
        "confidence": "high"}))
    return Settings(config_templates_dir=str(ct))


def test_installed_roles_matches_family_packages(tmp_path):
    s = _mk_configs(tmp_path)
    catalog = C.load_catalog(s)
    facts = {"os_family": "debian", "installed_packages": [{"name": "postgresql", "version": "16"}]}
    roles = [r for r, _, _ in C.installed_roles(facts, catalog)]
    assert roles == ["postgresql"]


def test_derive_rows_provider_and_consumer(tmp_path):
    s = _mk_configs(tmp_path)
    catalog = C.load_catalog(s)
    # a host running postgresql -> one provide row database:postgresql, port 5432
    prov_rows = C.derive_rows({"installed_packages": [{"name": "postgresql"}]}, catalog, s)
    assert len(prov_rows) == 1
    assert prov_rows[0]["kind"] == "provide" and prov_rows[0]["capability"] == "database"
    assert prov_rows[0]["backend"] == "postgresql" and prov_rows[0]["port"] == 5432
    # a host running roundcube -> one require row database (mysql|mariadb)
    req_rows = C.derive_rows({"installed_packages": [{"name": "roundcube-core"}]}, catalog, s)
    assert req_rows[0]["kind"] == "require" and req_rows[0]["detail"]["backends"] == ["mysql", "mariadb"]


def test_derive_rows_carries_peer_injection_onto_provide(tmp_path):
    s = _mk_configs(tmp_path)
    rows = C.derive_rows({"installed_packages": [{"name": "nfs-kernel-server"}]}, C.load_catalog(s), s)
    prov = next(r for r in rows if r["kind"] == "provide" and r["capability"] == "nfs")
    assert prov["detail"]["peer_injection"][0]["field"] == "exports"


def test_expand_backends_aliases(tmp_path):
    s = _mk_configs(tmp_path)
    # vocabulary ships mysql<->mariadb + redis->valkey/keydb; a consumer accepting mysql also accepts mariadb
    assert "mariadb" in C.expand_backends(s, ["mysql"])
    assert {"valkey", "keydb"} <= C.expand_backends(s, ["redis"])


def test_roles_providing(tmp_path):
    s = _mk_configs(tmp_path)
    roles = C.roles_providing(s, "database", "postgresql")
    assert any(r["role"] == "postgresql" for r in roles)
    # mysql is not provided by any role in this fixture
    assert C.roles_providing(s, "database", "mysql") == []


def test_propose_wiring_fills_consumer_fields():
    requirement = {"backends": ["mysql", "mariadb"], "backend_field": "db_host",
                   "fields": {"host": "db_host", "port": "db_port", "user": "db_user"}}
    provider = {"address": "10.0.0.5", "port": 3306, "backend": "mariadb", "detail": {}}
    wiring = C.propose_wiring(requirement, provider, consumer_address="10.0.0.9")
    assert wiring["consumer_values"]["db_host"] == "10.0.0.5"
    assert wiring["consumer_values"]["db_port"] == 3306
    # backend_field aliased onto db_host must NOT overwrite the host with a backend token
    assert wiring["consumer_values"]["db_host"] != "mariadb"


def test_propose_wiring_provider_peer_injection():
    requirement = {"fields": {"host": "server", "mount": "mountpoint"}}
    provider = {"address": "10.0.0.5", "port": None, "backend": "nfs",
                "detail": {"peer_injection": [{"field": "exports", "items_style": "items_fields"}]}}
    wiring = C.propose_wiring(requirement, provider, consumer_address="10.0.0.9")
    pi = wiring["provider_values"]["peer_injection"][0]
    assert pi["field"] == "exports" and pi["add_client"] == "10.0.0.9"
