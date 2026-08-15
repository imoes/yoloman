"""DB-backed tests for the capability derivation + matcher (services/capabilities.py) against a real
session. Skipped automatically when no database is reachable (the db_session fixture handles that).

Uses a throwaway configs/ tree via a patched Settings so it does not depend on which packages the live
catalog currently ships.
"""
from __future__ import annotations

import json
import uuid
from tests.naming import owned_name
from pathlib import Path

import pytest
from sqlalchemy import delete, select

from bossman.config import Settings
from bossman.db.models import Agent, HostCapability
from bossman.services import capabilities as C

pytestmark = pytest.mark.asyncio

_REPO_VOCAB = Path(__file__).resolve().parents[2] / "configs" / "capability_vocabulary.json"


def _settings(tmp: Path) -> Settings:
    ct = tmp / "config_templates"
    ct.mkdir(parents=True)
    (tmp / "capability_vocabulary.json").write_text(_REPO_VOCAB.read_text())
    (tmp / "package_catalog.json").write_text(json.dumps({
        "postgresql": {"template": "postgresql", "label": "PostgreSQL",
                       "families": {"debian": {"packages": ["postgresql"], "config_path": "/etc/postgresql/main.conf"}}},
        "roundcube": {"template": "roundcube", "label": "Roundcube",
                      "families": {"debian": {"packages": ["roundcube-core"], "config_path": "/etc/roundcube/x.php"}}},
    }))
    (ct / "postgresql").mkdir()
    (ct / "postgresql" / "capabilities.json").write_text(json.dumps({
        "provides": [{"capability": "database", "backend": "postgresql", "port_field": "port", "default_port": 5432}],
        "requires": [], "peer_injection": [], "confidence": "high"}))
    (ct / "roundcube").mkdir()
    (ct / "roundcube" / "capabilities.json").write_text(json.dumps({
        "provides": [],
        "requires": [{"capability": "database", "backends": ["postgresql", "mysql"],
                      "fields": {"host": "db_host", "port": "db_port"}}],
        "peer_injection": [], "confidence": "high"}))
    return Settings(config_templates_dir=str(ct))


async def _agent(db_session, name, packages, address):
    a = Agent(name=name, address=address, token=uuid.uuid4().hex, mode="standalone", enrollment_state="enrolled",
              facts={"os_family": "debian", "primary_ip": address,
                     "installed_packages": [{"name": p} for p in packages]})
    db_session.add(a)
    await db_session.flush()
    return a


async def _purge(db_session, *agents):
    for a in agents:
        await db_session.execute(delete(HostCapability).where(HostCapability.agent_id == a.id))
    await db_session.flush()
    for a in agents:
        await db_session.delete(a)
    await db_session.commit()


async def test_derive_and_match_end_to_end(db_session, tmp_path):
    settings = _settings(tmp_path)
    pg = await _agent(db_session, owned_name("pg"), ["postgresql"], "10.0.0.5")
    rc = await _agent(db_session, owned_name("rc"), ["roundcube-core"], "10.0.0.9")
    try:
        await C.derive_agent(db_session, pg, settings)
        await C.derive_agent(db_session, rc, settings)
        await db_session.flush()

        # the postgres host provides database:postgresql
        provs = await C.find_providers(db_session, settings, "database", ["postgresql", "mysql"],
                                       tenant_id=pg.tenant_id, exclude_agent=rc.id)
        assert any(p["agent_id"] == str(pg.id) and p["backend"] == "postgresql" and p["port"] == 5432
                   for p in provs)

        # the roundcube host's open requirement is database, and the matcher wires db_host -> pg address
        reqs = await C.open_requirements(db_session, rc.id)
        assert len(reqs) == 1 and reqs[0].capability == "database"
        provider = next(p for p in provs if p["agent_id"] == str(pg.id))
        wiring = C.propose_wiring(reqs[0].detail, provider, consumer_address="10.0.0.9")
        assert wiring["consumer_values"]["db_host"] == "10.0.0.5"
        assert wiring["consumer_values"]["db_port"] == 5432
    finally:
        await _purge(db_session, pg, rc)


async def test_reconcile_replaces_only_derived(db_session, tmp_path):
    settings = _settings(tmp_path)
    pg = await _agent(db_session, owned_name("pg"), ["postgresql"], "10.0.0.5")
    try:
        await C.derive_agent(db_session, pg, settings)
        await db_session.flush()
        # a hand-set explicit capability must survive a re-derive
        db_session.add(HostCapability(tenant_id=pg.tenant_id, agent_id=pg.id, kind="provide",
                                      capability="cache", backend="redis", template="manual", source="explicit"))
        await db_session.flush()
        await C.derive_agent(db_session, pg, settings)   # re-derive
        await db_session.flush()
        rows = list(await db_session.scalars(
            select(HostCapability).where(HostCapability.agent_id == pg.id)))
        kinds = {(r.capability, r.source) for r in rows}
        assert ("database", "derived") in kinds
        assert ("cache", "explicit") in kinds     # explicit row untouched by the derive reconcile
    finally:
        await _purge(db_session, pg)
