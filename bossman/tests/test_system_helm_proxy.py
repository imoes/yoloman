"""Admin-Settings helm chart-pull proxy (SystemSettings.helm_http_proxy) — the
DB-backed, UI-editable proxy that lets `helm show/pull` reach an internet OCI
registry from an agent host behind a corp firewall. See api/system_settings.py
and services/helm_app.set_helm_proxy / _proxied."""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from bossman.main import create_app
from bossman.services import helm_app
from bossman.services.auth import new_api_token


async def _token(db_session):
    row, raw = new_api_token("helm-proxy-caller")
    db_session.add(row)
    await db_session.commit()
    return {"Authorization": f"Bearer {raw}"}


def test_proxied_wraps_only_when_set():
    helm_app.set_helm_proxy("", "")
    assert helm_app._proxied(None, ["helm", "show", "values", "oci://x"]) == ["helm", "show", "values", "oci://x"]

    helm_app.set_helm_proxy("http://proxy.example:80", "localhost,.svc")
    wrapped = helm_app._proxied(None, ["helm", "show", "values", "oci://x"])
    assert wrapped[:2] == ["sh", "-c"]
    assert "HTTPS_PROXY=http://proxy.example:80" in wrapped[2]
    assert "NO_PROXY=localhost,.svc" in wrapped[2]
    assert "helm show values oci://x" in wrapped[2]
    helm_app.set_helm_proxy("", "")  # leave the module cache clean for other tests


def test_proxied_prepends_export_to_multi_statement_script():
    """render/install pass an `sh -c 'f=$(mktemp); helm upgrade ... -f $f'` script;
    the proxy must apply to the helm statement, not just the first — so `export`."""
    helm_app.set_helm_proxy("http://proxy.example:80", "")
    script = "f=$(mktemp); helm upgrade web oci://x -f $f"
    wrapped = helm_app._proxied(None, ["sh", "-c", script])
    assert wrapped[0] == "sh" and wrapped[1] == "-c"
    assert wrapped[2].startswith("export HTTPS_PROXY=")
    assert wrapped[2].endswith(script)
    helm_app.set_helm_proxy("", "")


@pytest.mark.asyncio
async def test_put_helm_proxy_persists_and_refreshes_cache(db_session):
    headers = await _token(db_session)
    helm_app.set_helm_proxy("", "")
    with TestClient(create_app()) as client:
        r = client.put(
            "/api/v1/system/helm-proxy",
            json={"http_proxy": "http://proxy.example.internal:80", "no_proxy": "localhost,.example.internal"},
            headers=headers,
        )
        assert r.status_code == 200
        assert r.json()["helm_http_proxy"] == "http://proxy.example.internal:80"

        got = client.get("/api/v1/system/yolo-mode", headers=headers)
        assert got.json()["helm_http_proxy"] == "http://proxy.example.internal:80"
        assert got.json()["helm_no_proxy"] == "localhost,.example.internal"

    # the write refreshed the in-process cache — the next helm command is proxied
    assert helm_app._HELM_PROXY[0] == "http://proxy.example.internal:80"
    # reset so we don't leave a proxy set for the rest of the suite
    with TestClient(create_app()) as client:
        client.put("/api/v1/system/helm-proxy", json={"http_proxy": "", "no_proxy": ""}, headers=headers)
