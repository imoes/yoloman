"""Deterministic Salt (.sls) → canonical plan parser (docs/zielbestimmung.md
roadmap). Pure parse tests + one store round-trip via prefix "salt".
"""

import pytest

from bossman.services.plan_loader import PlanError, build_plan_from_raw
from bossman.services.plan_store import load_plan, store_plan
from bossman.services.salt_parser import parse_salt_sls

SLS = """\
install_nginx:
  pkg.installed:
    - name: nginx

/etc/nginx/nginx.conf:
  file.managed:
    - source: salt://nginx.conf
    - mode: "0644"
    - user: root
    - group: root

/var/www:
  file.directory:
    - mode: "0755"

nginx_running:
  service.running:
    - name: nginx
    - enable: true
    - require:
      - pkg: install_nginx

install_htop:
  pkg:
    - installed
    - name: htop
"""


def _plan():
    raw = parse_salt_sls(SLS, "web")
    return build_plan_from_raw(raw, __import__("pathlib").Path("web"))


def test_salt_maps_states_to_modules():
    plan = _plan()
    assert plan.name == "web"
    steps = plan.chunks[0].steps
    names = [s.name for s in steps]
    assert names == ["install_nginx", "/etc/nginx/nginx.conf", "/var/www", "nginx_running", "install_htop"]

    by_name = {s.name: s for s in steps}
    assert by_name["install_nginx"].module == "package"
    assert by_name["install_nginx"].body == {"name": "nginx", "state": "present"}

    # file.managed → copy, with name→dest and Salt→ansible arg renames.
    conf = by_name["/etc/nginx/nginx.conf"]
    assert conf.module == "copy"
    assert conf.body["dest"] == "/etc/nginx/nginx.conf"
    assert conf.body["src"] == "salt://nginx.conf"
    assert conf.body["owner"] == "root" and conf.body["mode"] == "0644"

    # file.directory → file state=directory, name defaults to the state-ID.
    assert by_name["/var/www"].module == "file"
    assert by_name["/var/www"].body == {"path": "/var/www", "state": "directory", "mode": "0755"}

    # service.running → service started+enabled; the `require` requisite is dropped.
    svc = by_name["nginx_running"]
    assert svc.module == "service"
    assert svc.body == {"name": "nginx", "state": "started", "enabled": True}

    # shorthand "pkg: [installed, {name: htop}]"
    assert by_name["install_htop"].module == "package"
    assert by_name["install_htop"].body == {"name": "htop", "state": "present"}


def test_salt_unmapped_state_raises_clearly():
    with pytest.raises(PlanError, match="mysql_database.present.*not mapped"):
        parse_salt_sls("db:\n  mysql_database.present:\n    - name: app\n", "x")


def test_salt_rejects_non_mapping():
    with pytest.raises(PlanError, match="mapping"):
        parse_salt_sls("- just\n- a list\n", "x")


async def test_store_and_load_salt_plan(db_session):
    from sqlalchemy import select

    from bossman.db.models import PlanDocument

    doc = await store_plan(db_session, "salt", "web", "salt", SLS)
    assert doc.prefix == "salt" and doc.version == 1
    plan = await load_plan(db_session, "salt", "web")
    assert [s.module for s in plan.chunks[0].steps][:2] == ["package", "copy"]

    for row in (await db_session.scalars(select(PlanDocument).where(PlanDocument.prefix == "salt", PlanDocument.name == "web"))).all():
        await db_session.delete(row)
    await db_session.flush()
