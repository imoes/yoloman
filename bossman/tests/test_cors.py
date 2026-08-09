"""Real HTTP tests confirming bossman-ui (a different origin — its own
dev-server port, or a distinct production origin) can actually reach the
API. Found as a genuine bug, not a hypothetical one: bossman-ui's first
real login attempt against a real running Bossman hung silently in the
browser because FastAPI had no CORS middleware, so the preflight for a
POST carrying a JSON body/Authorization header was rejected before ever
reaching a route. See bossman/main.py and config.py's cors_allowed_origins.
"""

from fastapi.testclient import TestClient

from bossman.main import create_app


def test_preflight_allows_configured_origin(monkeypatch):
    monkeypatch.setenv("BOSSMAN_CORS_ALLOWED_ORIGINS", '["http://localhost:4300"]')
    app = create_app()

    with TestClient(app) as client:
        resp = client.options(
            "/api/v1/auth/login",
            headers={
                "Origin": "http://localhost:4300",
                "Access-Control-Request-Method": "POST",
                "Access-Control-Request-Headers": "content-type",
            },
        )

    assert resp.status_code == 200
    assert resp.headers["access-control-allow-origin"] == "http://localhost:4300"


def test_preflight_rejects_unconfigured_origin(monkeypatch):
    monkeypatch.setenv("BOSSMAN_CORS_ALLOWED_ORIGINS", '["http://localhost:4300"]')
    app = create_app()

    with TestClient(app) as client:
        resp = client.options(
            "/api/v1/auth/login",
            headers={
                "Origin": "http://evil.example.com",
                "Access-Control-Request-Method": "POST",
                "Access-Control-Request-Headers": "content-type",
            },
        )

    assert "access-control-allow-origin" not in resp.headers
