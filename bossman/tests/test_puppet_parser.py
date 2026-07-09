"""Deterministic Puppet manifest → canonical plan parser
(docs/zielbestimmung.md roadmap). Pure parse tests + a store round-trip.
"""

import pytest

from bossman.services.plan_loader import PlanError, build_plan_from_raw
from bossman.services.puppet_parser import parse_puppet_manifest

MANIFEST = """\
# nginx manifest
package { 'nginx':
  ensure => installed,
}

service { 'nginx':
  ensure  => running,
  enable  => true,
  require => Package['nginx'],
}

file { '/etc/motd':
  ensure  => file,
  content => 'welcome',
  mode    => '0644',
  owner   => 'root',
}

file { '/var/www':
  ensure => directory,
  mode   => '0755',
}

exec { 'reload':
  command => 'systemctl daemon-reload',
}
"""


def _plan():
    return build_plan_from_raw(parse_puppet_manifest(MANIFEST, "web"), __import__("pathlib").Path("web"))


def test_puppet_maps_resources():
    by = {s.name: s for s in _plan().chunks[0].steps}
    assert set(by) == {"package[nginx]", "service[nginx]", "file[/etc/motd]", "file[/var/www]", "exec[reload]"}
    assert by["package[nginx]"].module == "package"
    assert by["package[nginx]"].body == {"name": "nginx", "state": "present"}
    # require metaparameter dropped; ensure=running + enable=true
    assert by["service[nginx]"].body == {"name": "nginx", "state": "started", "enabled": True}
    assert by["file[/etc/motd]"].module == "copy"
    assert by["file[/etc/motd]"].body == {"dest": "/etc/motd", "content": "welcome", "mode": "0644", "owner": "root"}
    assert by["file[/var/www]"].body == {"path": "/var/www", "state": "directory", "mode": "0755"}
    assert by["exec[reload]"].body == {"cmd": "systemctl daemon-reload"}


def test_puppet_oneline_resource():
    by = {s.name: s for s in build_plan_from_raw(
        parse_puppet_manifest("package { 'htop': ensure => installed }", "x"), __import__("pathlib").Path("x")
    ).chunks[0].steps}
    assert by["package[htop]"].body == {"name": "htop", "state": "present"}


def test_puppet_rejects_classes_and_conditionals():
    with pytest.raises(PlanError, match="flat resource declarations"):
        parse_puppet_manifest("class nginx {\n  package { 'nginx': ensure => installed }\n}\n", "x")
    with pytest.raises(PlanError, match="flat resource declarations"):
        parse_puppet_manifest("if $x {\n  package { 'a': }\n}\n", "x")


def test_puppet_rejects_variables_and_interpolation():
    with pytest.raises(PlanError, match="flat resource declarations"):
        parse_puppet_manifest("file { '/x': content => \"${foo}\" }\n", "x")


def test_puppet_reports_unparsed_content():
    # A stray non-resource statement must not be silently ignored.
    with pytest.raises(PlanError, match="unparsed manifest content"):
        parse_puppet_manifest("notify { 'hi': }\nsomething_bogus here\n", "x")


def test_puppet_unmapped_resource_raises():
    with pytest.raises(PlanError, match="cron.*not mapped"):
        parse_puppet_manifest("cron { 'job': command => 'x' }\n", "x")


async def test_store_and_load_puppet_plan(db_session):
    from sqlalchemy import select

    from bossman.db.models import PlanDocument
    from bossman.services.plan_store import load_plan, store_plan

    doc = await store_plan(db_session, "puppet", "web", "puppet", MANIFEST)
    assert doc.prefix == "puppet" and doc.version == 1
    plan = await load_plan(db_session, "puppet", "web")
    assert [s.module for s in plan.chunks[0].steps][:2] == ["package", "service"]

    for row in (await db_session.scalars(select(PlanDocument).where(PlanDocument.prefix == "puppet", PlanDocument.name == "web"))).all():
        await db_session.delete(row)
    await db_session.flush()
