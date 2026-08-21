"""GET /api/v1/config-fields — the ONE describe() the editors ask.

This endpoint answers "what fields does this file have, and how is it written?", and every field editor in
the UI now resolves through it. It had no test, which is how two of its answers came to contradict the
artifacts they are built from:

  * `write` was computed as `"codec" if codec_kind else "unknown"`, and the string "none" is truthy — so a
    file whose codec record says "no grammar reproduces this file" was answered as write="codec",
    format="none", fields={}. The record said one thing and the API the opposite about the same file.
  * a freeform path resolved its template by BASENAME, which put /etc/named.conf on the Debian bind9
    template that renders /etc/bind/named.conf. The write is whole-file, so that answer would have replaced
    one file's content with another's.

Both are pinned below, together with the fourth state (`unknown`: nothing recorded at all) and the
machine-written advisory, which is the file's own sentence carried through untouched.
"""

import json

from fastapi.testclient import TestClient

from bossman.config import Settings, get_settings
from bossman.main import create_app
from bossman.services.auth import new_api_token


def _catalogs(tmp_path):
    """A registry with one file per write state, and a template that RECORDS its target path."""
    (tmp_path / "config_codecs.json").write_text(json.dumps({
        "/etc/keyed.conf": {"codec": "keyvalue", "separator": "=", "source": "probe",
                            "paths": ["/etc/keyed.conf"]},
        # Measured `none`: every codec was applied to the shipped bytes and none reproduced the file.
        "/etc/whole.conf": {"codec": "none", "source": "probe", "paths": ["/etc/whole.conf"]},
        "/etc/raw.conf": {"codec": "none", "source": "probe", "paths": ["/etc/raw.conf"]},
        "/etc/munin/munin.conf": {"codec": "keyvalue", "separator": " ", "source": "probe",
                                  "paths": ["/etc/munin/munin.conf"]},
    }))
    (tmp_path / "config_directives.json").write_text(json.dumps({
        "/etc/keyed.conf": {"Port": {"type": "int", "default": "22", "description": "The port"}},
        "/etc/munin/munin.conf": {"dbdir": {"type": "string", "description": "Where munin writes"}},
    }))
    (tmp_path / "package_catalog.json").write_text(json.dumps({}))
    tpl = tmp_path / "config_templates"
    (tpl / "whole-tpl").mkdir(parents=True)
    (tpl / "whole-tpl" / "template.j2").write_text("setting = {{ setting }}\n")
    (tpl / "whole-tpl" / "schema.json").write_text(json.dumps(
        {"setting": {"type": "string"}, "ignored_setting": {"type": "string"}}))
    (tpl / "whole-tpl" / "meta.json").write_text(json.dumps(
        {"target_path": "/etc/whole.conf", "witness": "rpm", "source": "rh-parametrize"}))
    # The file's own words. Recorded by scripts/find_generated_files.py from the shipped bytes.
    (tmp_path / "config_generated.json").write_text(json.dumps({
        "/etc/munin/munin.conf": {"line": 3, "marker": "don't edit",
                                  "quote": "# Please don't edit this example config file. Create and edit"},
    }))
    return tpl


async def _token(db_session):
    token, raw = new_api_token("config-fields-test")
    db_session.add(token)
    await db_session.flush()
    await db_session.commit()
    return token, raw


async def test_the_four_write_states_and_the_file_s_own_advisory(db_session, tmp_path):
    tpl = _catalogs(tmp_path)
    token, raw = await _token(db_session)

    app = create_app()
    base = get_settings()
    app.dependency_overrides[get_settings] = lambda: Settings(
        database_url=base.database_url,
        config_codecs_path=str(tmp_path / "config_codecs.json"),
        config_directives_path=str(tmp_path / "config_directives.json"),
        config_templates_dir=str(tpl),
        config_generated_path=str(tmp_path / "config_generated.json"),
    )
    headers = {"Authorization": f"Bearer {raw}"}
    with TestClient(app) as client:
        assert client.get("/api/v1/config-fields?path=/etc/keyed.conf").status_code == 401
        keyed = client.get("/api/v1/config-fields?path=/etc/keyed.conf", headers=headers).json()
        whole = client.get("/api/v1/config-fields?path=/etc/whole.conf", headers=headers).json()
        raw_file = client.get("/api/v1/config-fields?path=/etc/raw.conf", headers=headers).json()
        never = client.get("/api/v1/config-fields?path=/etc/nothing.conf", headers=headers).json()
        munin = client.get("/api/v1/config-fields?path=/etc/munin/munin.conf", headers=headers).json()
        listing = client.get("/api/v1/config-generated", headers=headers).json()

    # A codec that round-tripped the shipped bytes: merge per key, fields from the directive catalog.
    assert keyed["write"] == "codec" and keyed["format"] == "keyvalue"
    assert keyed["fields"]["Port"]["type"] == "int"

    # Measured `none` PLUS a template that records this exact path: whole-file write, fields from its schema.
    assert whole["write"] == "template" and whole["fields"] == {"setting": {"type": "string"}}
    assert whole["provenance"]["measured"] is True
    # A field the template never places is WITHHELD and counted, not offered and then dropped by the write.
    # Measured across the library: 2561 of 54026 offered fields (341 templates) appear nowhere in their
    # body — acme.sh offers 69 and places 5.
    assert whole["withheld"]["fields"] == ["ignored_setting"]
    assert "could not reach the file" in whole["withheld"]["reason"]

    # Measured `none` and no template claims it. NOT "codec with zero fields" — the states are distinct
    # and the reason is stated, because a refusal without a ground is indistinguishable from a bug.
    assert raw_file["write"] == "freeform" and raw_file["available"] is False
    assert "no codec fits" in raw_file["reason"]

    # Nothing has ever been recorded about this path — a different claim from "measured, nothing fits".
    assert never["write"] == "unknown" and "nothing is known" in never["reason"]

    # The advisory rides along on a perfectly editable file, verbatim and without a verdict: munin.conf is
    # parsable and has directives, and munin still says not to edit it. Only the file can say which.
    assert munin["write"] == "codec" and munin["fields"]["dbdir"]["type"] == "string"
    assert munin["machine_written"]["line"] == 3
    assert "don't edit this example config file" in munin["machine_written"]["quote"]
    assert "machine_written" not in keyed          # only where the file says so
    assert listing["count"] == 1 and "/etc/munin/munin.conf" in listing["files"]

    await db_session.delete(token)
    await db_session.commit()
