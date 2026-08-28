"""The native install serves the web console itself; the Docker one lets nginx do it.

Every case here was a real failure of the shipped .deb before it was a test:
  - a deep link 404'd, because StaticFiles(html=True) only serves index.html for a DIRECTORY;
  - the first fix checked the returned status code, but StaticFiles RAISES 404, so it caught nothing;
  - and a catch-all at "/" would answer a mistyped /api/v1/... with the app and HTTP 200, turning a
    caller's bug into a silent success.
"""

from fastapi import FastAPI
from fastapi.testclient import TestClient

from bossman.main import _mount_ui


def _app(tmp_path, write_index=True):
    if write_index:
        (tmp_path / "index.html").write_text("<app-root></app-root>")
        (tmp_path / "main.js").write_text("// bundle")
    app = FastAPI()

    @app.get("/api/v1/real")
    def real():
        return {"ok": True}

    _mount_ui(app, str(tmp_path))
    return TestClient(app)


def test_the_console_is_served_at_the_root(tmp_path):
    r = _app(tmp_path).get("/")
    assert r.status_code == 200 and "app-root" in r.text


def test_a_real_asset_is_served_as_itself(tmp_path):
    r = _app(tmp_path).get("/main.js")
    assert r.status_code == 200 and "bundle" in r.text


def test_a_deep_link_falls_back_to_index(tmp_path):
    # What a browser reload of /hosts/<id>?tab=config does. Without the fallback the operator gets a 404 on
    # a page that works when reached by clicking.
    r = _app(tmp_path).get("/hosts/abc-123")
    assert r.status_code == 200 and "app-root" in r.text


def test_a_real_api_route_still_wins(tmp_path):
    assert _app(tmp_path).get("/api/v1/real").json() == {"ok": True}


def test_a_mistyped_api_path_still_404s(tmp_path):
    # The important one. A fallback that answered here would report success for a route that does not exist.
    r = _app(tmp_path).get("/api/v1/definitely-not-a-route")
    assert r.status_code == 404


def test_mcp_and_healthz_are_excluded_too(tmp_path):
    client = _app(tmp_path)
    assert client.get("/mcp/nope").status_code == 404
    assert client.get("/healthz").status_code == 404   # not mounted in this bare app; must not be swallowed


def test_no_ui_dir_means_no_mount(tmp_path):
    # The Docker deployment: nginx serves the console, so this app must not.
    app = FastAPI()
    _mount_ui(app, "")
    assert TestClient(app).get("/").status_code == 404


def test_a_ui_dir_without_index_is_refused_loudly(tmp_path):
    # An empty bind mount is how the Docker deployment once came up "healthy" with no console at all. A
    # missing index.html must not produce a mount that serves nothing.
    app = FastAPI()
    _mount_ui(app, str(tmp_path))          # tmp_path is empty
    assert TestClient(app).get("/").status_code == 404
