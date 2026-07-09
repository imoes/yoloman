"""Deterministic Chef recipe → canonical plan parser (docs/zielbestimmung.md
roadmap). Pure parse tests + a store round-trip via prefix "chef".
"""

import pytest

from bossman.services.chef_parser import parse_chef_recipe
from bossman.services.plan_loader import PlanError, build_plan_from_raw

RECIPE = """\
# install and run nginx
package 'nginx' do
  action :install
end

service 'nginx' do
  action [:enable, :start]
end

file '/etc/motd' do
  content 'welcome'
  mode '0644'
  owner 'root'
end

directory '/var/www' do
  mode '0755'
  action :create
end

execute 'refresh' do
  command 'systemctl daemon-reload'
end

package 'htop'
"""


def _plan():
    raw = parse_chef_recipe(RECIPE, "web")
    return build_plan_from_raw(raw, __import__("pathlib").Path("web"))


def test_chef_maps_resources_to_modules():
    steps = _plan().chunks[0].steps
    by = {s.name: s for s in steps}
    assert set(by) == {
        "package[nginx]", "service[nginx]", "file[/etc/motd]",
        "directory[/var/www]", "execute[refresh]", "package[htop]",
    }
    assert by["package[nginx]"].module == "package"
    assert by["package[nginx]"].body == {"name": "nginx", "state": "present"}
    # action [:enable, :start] → started + enabled
    assert by["service[nginx]"].body == {"name": "nginx", "state": "started", "enabled": True}
    # file → copy, path defaults to the resource name
    assert by["file[/etc/motd]"].module == "copy"
    assert by["file[/etc/motd]"].body == {"dest": "/etc/motd", "content": "welcome", "mode": "0644", "owner": "root"}
    assert by["directory[/var/www]"].body == {"path": "/var/www", "state": "directory", "mode": "0755"}
    assert by["execute[refresh]"].body == {"cmd": "systemctl daemon-reload"}
    # one-liner uses the default action
    assert by["package[htop]"].body == {"name": "htop", "state": "present"}


def test_chef_rejects_ruby_interpolation():
    with pytest.raises(PlanError, match="interpolation"):
        parse_chef_recipe("file '/x' do\n  content \"#{node['x']}\"\nend\n", "x")


def test_chef_rejects_control_flow():
    with pytest.raises(PlanError, match="unsupported Ruby construct"):
        parse_chef_recipe("if node['x']\n  package 'a'\nend\n", "x")


def test_chef_unmapped_resource_raises():
    with pytest.raises(PlanError, match="cron_d.*not mapped"):
        parse_chef_recipe("cron_d 'job' do\n  minute '5'\nend\n", "x")


def test_chef_unterminated_resource_raises():
    with pytest.raises(PlanError, match="unterminated"):
        parse_chef_recipe("package 'nginx' do\n  action :install\n", "x")


async def test_store_and_load_chef_plan(db_session):
    from sqlalchemy import select

    from bossman.db.models import PlanDocument
    from bossman.services.plan_store import load_plan, store_plan

    doc = await store_plan(db_session, "chef", "web", "chef", RECIPE)
    assert doc.prefix == "chef" and doc.version == 1
    plan = await load_plan(db_session, "chef", "web")
    assert [s.module for s in plan.chunks[0].steps][:2] == ["package", "service"]

    for row in (await db_session.scalars(select(PlanDocument).where(PlanDocument.prefix == "chef", PlanDocument.name == "web"))).all():
        await db_session.delete(row)
    await db_session.flush()
