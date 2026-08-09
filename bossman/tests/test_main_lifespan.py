"""Real, DB-backed test for bossman.main's lifespan startup behavior —
see tests/conftest.py's db_session fixture (skips if no DB is reachable).

Covers a real bug found while exercising bossman-ui's "run a plan" flow
against a directly-inserted Agent row (not enrolled via /api/v1/enroll):
Bossman's own mTLS client keypair was only ever created as a side effect
of the enrollment handler, so polling/plan-running against an agent added
any other way silently failed deep inside AgentClient with a bare
FileNotFoundError. bossman/main.py's lifespan now ensures the keypair
unconditionally at startup — this test proves that actually happens.
"""

from fastapi.testclient import TestClient

from bossman.main import create_app


async def test_lifespan_creates_client_keypair_if_missing(db_session, tmp_path, monkeypatch):
    key_path = tmp_path / "bossman-client.key"
    cert_path = tmp_path / "bossman-client.crt"
    monkeypatch.setenv("BOSSMAN_CLIENT_KEY_PATH", str(key_path))
    monkeypatch.setenv("BOSSMAN_CLIENT_CERT_PATH", str(cert_path))
    assert not key_path.exists()
    assert not cert_path.exists()

    app = create_app()
    with TestClient(app):
        pass

    assert key_path.exists()
    assert cert_path.exists()


async def test_lifespan_reuses_existing_client_keypair(db_session, tmp_path, monkeypatch):
    key_path = tmp_path / "bossman-client.key"
    cert_path = tmp_path / "bossman-client.crt"
    monkeypatch.setenv("BOSSMAN_CLIENT_KEY_PATH", str(key_path))
    monkeypatch.setenv("BOSSMAN_CLIENT_CERT_PATH", str(cert_path))

    with TestClient(create_app()):
        pass
    first_cert = cert_path.read_bytes()

    with TestClient(create_app()):
        pass
    second_cert = cert_path.read_bytes()

    assert first_cert == second_cert
