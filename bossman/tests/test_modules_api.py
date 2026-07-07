"""Tests for GET /api/v1/modules — the module-management REST surface
(Block H4). Real app + real api-token auth (same credential pattern as
tests/test_agents_api.py); the library/source dirs are pointed at a tmp
tree via FastAPI dependency_overrides."""

import json

from fastapi.testclient import TestClient

from bossman.config import Settings, get_settings
from bossman.main import create_app
from bossman.services.auth import new_api_token


def _library(tmp_path):
    sources = tmp_path / "module_sources"
    sources.mkdir()
    (sources / "ansible.posix.sysctl.json").write_text(
        json.dumps(
            {
                "fqcn": "ansible.posix.sysctl",
                "name": "sysctl",
                "collection": "ansible.posix",
                "short_description": "Manage sysctl",
                "doc": {"options": {"name": {"type": "str", "required": True}}},
            }
        )
    )
    (sources / "community.general.timezone.json").write_text(
        json.dumps(
            {
                "fqcn": "community.general.timezone",
                "name": "timezone",
                "collection": "community.general",
                "short_description": "Set timezone",
                "doc": {"options": {"name": {"type": "str", "required": True}}},
            }
        )
    )
    modules_dir = tmp_path / "modules.d"
    (modules_dir / "ansible.posix").mkdir(parents=True)
    (modules_dir / "ansible.posix" / "sysctl.yaml").write_text(
        "name: sysctl\nfqcn: ansible.posix.sysctl\ncollection: ansible.posix\n"
        "short_description: Manage sysctl\noptions: {}\nwrites: true\nruntime: starlark\n"
    )
    (modules_dir / "ansible.posix" / "sysctl.star").write_text("def main(ctx, params):\n    return {}\n")
    return modules_dir, sources


async def test_modules_endpoints(db_session, tmp_path):
    modules_dir, sources = _library(tmp_path)
    api_token, raw = await (make_token(db_session))

    app = create_app()
    base = get_settings()
    app.dependency_overrides[get_settings] = lambda: Settings(
        database_url=base.database_url,
        modules_dir=str(modules_dir),
        module_sources_dir=str(sources),
    )
    headers = {"Authorization": f"Bearer {raw}"}
    with TestClient(app) as client:
        unauth = client.get("/api/v1/modules")
        listing = client.get("/api/v1/modules", headers=headers)
        translated = client.get("/api/v1/modules/ansible.posix.sysctl", headers=headers)
        pending = client.get("/api/v1/modules/community.general.timezone", headers=headers)
        missing = client.get("/api/v1/modules/community.general.nope", headers=headers)

    assert unauth.status_code == 401
    assert listing.status_code == 200
    body = listing.json()
    assert body["total"] == 2 and body["translated"] == 1
    assert body["collections"]["ansible.posix"] == {"total": 1, "translated": 1}
    by_fqcn = {m["fqcn"]: m for m in body["modules"]}
    assert by_fqcn["ansible.posix.sysctl"]["translated"] is True
    assert by_fqcn["community.general.timezone"]["translated"] is False

    assert translated.status_code == 200
    t = translated.json()
    assert t["translated"] is True and "def main" in t["star_code"]

    assert pending.status_code == 200
    p = pending.json()
    assert p["translated"] is False
    assert p["metadata"]["options"]["name"]["required"] is True
    assert p["star_code"] == ""

    assert missing.status_code == 404

    await db_session.delete(api_token)
    await db_session.flush()
    await db_session.commit()


async def make_token(db_session, name="modules-api-test"):
    token, raw = new_api_token(name)
    db_session.add(token)
    await db_session.flush()
    await db_session.commit()
    return token, raw
