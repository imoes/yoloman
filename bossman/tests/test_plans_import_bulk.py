"""Directory import: a re-import changes nothing, and a second tree never overwrites the first.

Every Ansible role has a `tasks/main.yml`; names come from the path relative to the tree root, so two roles
produce the same runbook name. Before, the second import silently replaced the first role's runbook and both
calls answered "imported". Now each entry says what it did (created / updated / unchanged) and a name taken in
another folder is refused with the place it is taken.
"""

from fastapi.testclient import TestClient
from sqlalchemy import delete

from bossman.config import get_settings
from bossman.db.models import Runbook
from bossman.main import create_app
from bossman.services.auth import create_access_token, new_bossman_user
from tests.naming import owned_name

TASKS = "- name: install tree\n  package:\n    name: tree\n    state: present\n"


async def test_reimport_is_unchanged_and_other_folder_is_refused(db_session):
    user = new_bossman_user(owned_name("bulk"), "pw", "admin")
    db_session.add(user)
    await db_session.commit()
    headers = {"Authorization": f"Bearer {create_access_token(user, get_settings())}"}
    root = owned_name("bulkrole")
    path = f"{root}/tasks/main.yml"
    name = f"{root}-tasks-main"
    folder = owned_name("imported")
    try:
        with TestClient(create_app()) as client:
            def run(dry_run: bool, folder_: str, text: str = TASKS) -> dict:
                r = client.post("/api/v1/plans/import-bulk", headers=headers, json={
                    "files": [{"path": path, "text": text}, {"path": f"{root}/templates/motd.j2", "text": "hi"}],
                    "folder": folder_, "dry_run": dry_run})
                assert r.status_code == 200, r.text
                return r.json()

            preview = run(True, folder)
            assert [(i["name"], i["status"]) for i in preview["imported"]] == [(name, "created")]
            assert preview["skipped"][0]["path"].endswith("motd.j2")
            listed = [rb["name"] for rb in client.get("/api/v1/runbooks", headers=headers).json()["runbooks"]]
            assert name not in listed, "a preview writes nothing"

            assert run(False, folder)["imported"][0]["status"] == "created"
            assert run(False, folder)["imported"][0]["status"] == "unchanged"
            changed = TASKS.replace("tree", "htop")
            assert run(False, folder, changed)["imported"][0]["status"] == "updated"
            names = [rb["name"] for rb in client.get("/api/v1/runbooks", headers=headers).json()["runbooks"]]
            assert names.count(name) == 1

            other = run(False, owned_name("elsewhere"))
            assert not other["imported"]
            assert folder in other["failed"][0]["error"]
    finally:
        await db_session.execute(delete(Runbook).where(Runbook.name == name))
        await db_session.delete(user)
        await db_session.commit()
