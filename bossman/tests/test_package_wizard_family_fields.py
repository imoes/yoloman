"""The wizard context names the fields a family's own template has, so the form can grey out the rest."""

import json

from bossman.api import package_wizard


def test_family_fields_come_from_family_templates_only(tmp_path):
    for name, meta, schema in [
        ("squid", {"target_path": "/etc/squid/squid.conf"}, {"http_port": {}, "cache_mem": {}}),
        ("squid-redhat", {"target_path": "/etc/squid/squid.conf", "family": "redhat"}, {"http_port": {}}),
    ]:
        d = tmp_path / "config_templates" / name
        d.mkdir(parents=True)
        (d / "meta.json").write_text(json.dumps(meta))
        (d / "schema.json").write_text(json.dumps(schema))

    class S:
        config_templates_dir = str(tmp_path / "config_templates")

    package_wizard._FAMILY_FIELDS_CACHE.clear()
    got = package_wizard._family_fields(S())
    assert got == {("redhat", "/etc/squid/squid.conf"): ["http_port"]}
