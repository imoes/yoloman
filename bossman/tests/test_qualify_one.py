"""The qualify pipeline's reusable pieces — the ones the on-demand endpoint calls instead of spawning a
subprocess, plus the path resolution that made a duplicate of the whole 1600-line tool necessary.

No LLM is touched here. What is pinned is the plumbing that decides WHICH package gets qualified, WHERE the
catalog is, and whether a run's outcome survives the trip back to the caller — each of which was wrong in a
way that produced a plausible-looking answer rather than a failure.
"""

import json
import os
from pathlib import Path

import pytest

from bossman.tools._paths import configs_dir, repo_root
from bossman.tools.qualify_packages import build_entry_map


def test_a_package_inherits_its_ROLE_config_path(tmp_path):
    """The measured bug this map exists for: `libvirt-daemon` has no catalog entry of its own, so the
    template stage saw no config_path and templated /etc/default/libvirtd (6 SysV variables) instead of
    /etc/libvirt/libvirtd.conf (17 kB). The role knows the path; the package had no way to ask.

    Pinned because the on-demand endpoint used to be a separate code path — one that could resolve the same
    package differently and quietly produce a different template for it."""
    catalog = {
        "libvirtd": {"template": "libvirtd", "label": "libvirt",
                     "families": {"debian": {"packages": ["libvirt-daemon-system", "libvirt-daemon"],
                                             "config_path": "/etc/libvirt/libvirtd.conf"}}},
    }
    entries = build_entry_map(catalog)
    assert entries["libvirt-daemon"]["name"] == "libvirtd"
    assert entries["libvirt-daemon"]["families"]["debian"]["config_path"] == "/etc/libvirt/libvirtd.conf"
    # And by template name, which is how the batch's own worklist (template dirs) addresses it.
    assert entries["libvirtd"]["name"] == "libvirtd"


def test_the_template_mapping_wins_over_the_package_mapping():
    """setdefault order is load-bearing: a name that is BOTH some role's template and another role's
    package must resolve to the template's own entry, or a package would hijack a template's config path."""
    catalog = {
        "role-a": {"template": "shared", "families": {"debian": {"config_path": "/etc/a.conf"}}},
        "role-b": {"template": "b", "families": {"debian": {"packages": ["shared"],
                                                            "config_path": "/etc/b.conf"}}},
    }
    entries = build_entry_map(catalog)
    assert entries["shared"]["name"] == "role-a"


# --------------------------------------------------------------------------- path resolution

def test_the_root_is_found_not_counted(tmp_path, monkeypatch):
    """parents[2] is the repo root in the container and ONE SHORT in a checkout, which is why a patched
    duplicate of every tool used to live in bossman/scripts/. Both layouts must resolve here."""
    monkeypatch.delenv("AGENTIC_CONFIGS_DIR", raising=False)
    for layout in ("app/bossman/tools", "repo/bossman/bossman/tools"):
        root = tmp_path / layout.split("/")[0]
        tool = tmp_path / layout / "x.py"
        tool.parent.mkdir(parents=True)
        tool.write_text("")
        (root / "configs").mkdir(parents=True)
        (root / "configs" / "config_codecs.json").write_text("{}")
        assert repo_root(tool) == root, layout
        assert configs_dir(tool) == root / "configs", layout


def test_an_empty_configs_directory_does_not_win(tmp_path, monkeypatch):
    """The case that broke it: `bossman/configs/` exists in this checkout — root-owned empty dirs a container
    bind-mount left behind. A plain "is there a configs/ dir" test picked THAT, so the pipeline looked for
    bossman/configs/config_templates and died in iterdir()."""
    monkeypatch.delenv("AGENTIC_CONFIGS_DIR", raising=False)
    real = tmp_path / "repo"
    tool = real / "bossman" / "bossman" / "tools" / "x.py"
    tool.parent.mkdir(parents=True)
    tool.write_text("")
    (real / "configs" / "config_templates").mkdir(parents=True)   # the real catalog
    (real / "bossman" / "configs" / "checks.d").mkdir(parents=True)  # the bind-mount leftover
    assert repo_root(tool) == real


def test_the_env_override_wins(tmp_path, monkeypatch):
    """The container passes AGENTIC_CONFIGS_DIR, and pointing the pipeline at a different catalog is a
    legitimate thing to do — not a fallback for when the search fails."""
    monkeypatch.setenv("AGENTIC_CONFIGS_DIR", str(tmp_path / "elsewhere"))
    assert configs_dir(__file__) == tmp_path / "elsewhere"


# --------------------------------------------------------------------------- reporting the outcome

def test_the_codec_is_read_the_way_the_file_is_shaped(tmp_path, monkeypatch):
    """The endpoint reported `codec: null` and `directives_keys: 0` for every package, always. It read
    `codecs.get("packages", {})` — and config_codecs.json has no top-level "packages" key: it is keyed by
    PATH, each entry carrying the packages that ship it. A wrong lookup that returns a plausible value is
    worse than one that raises."""
    from bossman.api import package_qualify

    (tmp_path / "config_codecs.json").write_text(json.dumps({
        "/etc/nginx/nginx.conf": {"codec": "nginx", "packages": ["nginx"], "paths": ["/etc/nginx/nginx.conf"]},
        "/etc/other.conf": {"codec": "keyvalue", "packages": ["unrelated"]},
    }))
    (tmp_path / "config_directives.json").write_text(json.dumps({
        "/etc/nginx/nginx.conf": {"worker_processes": {}, "worker_connections": {}},
    }))
    monkeypatch.setattr(package_qualify, "_CONFIGS_DIR", tmp_path)
    codec, keys = package_qualify._recorded_codec("nginx")
    assert codec == "nginx"
    assert keys == 2
    assert package_qualify._recorded_codec("nobody-ships-this") == (None, 0)


def test_a_later_none_codec_does_not_erase_the_answer(tmp_path, monkeypatch):
    """A package owning several files: one parsable, one free-form. Taking the last match would report
    `none` for a package whose config IS parsable."""
    from bossman.api import package_qualify

    (tmp_path / "config_codecs.json").write_text(json.dumps({
        "/etc/aaa/main.conf": {"codec": "ini", "packages": ["pkg"]},
        "/etc/zzz/blob.conf": {"codec": "none", "packages": ["pkg"]},
    }))
    (tmp_path / "config_directives.json").write_text("{}")
    monkeypatch.setattr(package_qualify, "_CONFIGS_DIR", tmp_path)
    assert package_qualify._recorded_codec("pkg")[0] == "ini"


def test_missing_files_are_an_absence_not_a_crash(tmp_path, monkeypatch):
    from bossman.api import package_qualify

    monkeypatch.setattr(package_qualify, "_CONFIGS_DIR", tmp_path / "nothing-here")
    assert package_qualify._recorded_codec("nginx") == (None, 0)
    assert package_qualify._catalog_category("nginx") is None


@pytest.mark.parametrize("name", ["", "  ", "../etc/passwd", "a/b"])
async def test_a_name_that_is_a_path_is_refused(name):
    from fastapi import HTTPException

    from bossman.api.package_qualify import run_qualify

    with pytest.raises(HTTPException) as exc:
        await run_qualify(name)
    assert exc.value.status_code == 422


async def test_an_already_current_package_says_so_instead_of_claiming_a_build(monkeypatch, tmp_path):
    """The old behaviour: an up-to-date package fell out of the batch's `pending` list, nothing ran, and the
    caller was told ok=true with template_created=true — indistinguishable from a fresh build. `force` is
    how a caller asks for the rebuild."""
    from bossman.api import package_qualify

    monkeypatch.setattr(package_qualify, "_CONFIGS_DIR", tmp_path)
    (tmp_path / "config_codecs.json").write_text(json.dumps(
        {"/etc/demo.conf": {"codec": "keyvalue", "packages": ["demo"]}}))
    (tmp_path / "config_directives.json").write_text("{}")
    (tmp_path / "package_catalog.json").write_text(json.dumps({"demo": {"category": "network"}}))

    called: dict = {}

    async def _fake_qualify_one(name, **kw):
        called.update({"name": name, **kw})
        return {"status": "ok", "already_current": True, "cleared": [], "flushed": False}

    import bossman.tools.qualify_packages as qp
    monkeypatch.setattr(qp, "qualify_one", _fake_qualify_one)
    # The catalog rebuild must NOT run when nothing changed — rebuilding the whole catalog to record a
    # change that did not happen is minutes of work for no reason.
    import bossman.tools.build_package_catalog as bpc
    monkeypatch.setattr(bpc, "main", lambda: (_ for _ in ()).throw(AssertionError("rebuilt for nothing")))

    res = await package_qualify.run_qualify("demo")
    assert res.already_current is True
    assert res.status == "already-current"
    assert res.ok is True
    # Nothing ran, so the values come from the FILES — and they are the real ones, not null/0.
    assert res.codec == "keyvalue"
    assert res.category == "network"
    assert called["name"] == "demo"


async def test_an_llm_failure_is_not_reported_as_ok(monkeypatch, tmp_path):
    """`status: failed` means a step's LLM was unreachable, and the package is deliberately left unmarked so
    a later pass retries it. Reporting that as ok would make the retry look like a fresh failure."""
    from bossman.api import package_qualify

    monkeypatch.setattr(package_qualify, "_CONFIGS_DIR", tmp_path)
    (tmp_path / "package_catalog.json").write_text("{}")

    async def _fake_qualify_one(name, **kw):
        return {"status": "failed", "already_current": False, "codec": "ini",
                "llm_errors": ["template: connection refused"], "enums": 0}

    import bossman.tools.build_package_catalog as bpc
    import bossman.tools.qualify_packages as qp
    monkeypatch.setattr(qp, "qualify_one", _fake_qualify_one)
    monkeypatch.setattr(bpc, "main", lambda: 0)

    res = await package_qualify.run_qualify("demo")
    assert res.ok is False
    assert res.status == "failed"
    # The ground for the refusal, not just the refusal.
    assert "connection refused" in (res.detail or "")


async def test_a_skip_is_ok_and_names_its_reason(monkeypatch, tmp_path):
    """"This package ships no config" is a correct outcome, not a failure — but it has to say which."""
    from bossman.api import package_qualify

    monkeypatch.setattr(package_qualify, "_CONFIGS_DIR", tmp_path)
    (tmp_path / "package_catalog.json").write_text("{}")

    async def _fake_qualify_one(name, **kw):
        return {"status": "skip", "reason": "no config (no /etc in .deb, no man5)", "already_current": False}

    import bossman.tools.build_package_catalog as bpc
    import bossman.tools.qualify_packages as qp
    monkeypatch.setattr(qp, "qualify_one", _fake_qualify_one)
    monkeypatch.setattr(bpc, "main", lambda: 0)

    res = await package_qualify.run_qualify("fonts-foo")
    assert res.ok is True and res.status == "skip"
    assert "no config" in (res.detail or "")


def test_the_run_env_never_overrides_a_configured_deployment(monkeypatch):
    """setdefault, not assignment: a deployment that points the pipeline somewhere keeps its choice."""
    from bossman.api.package_qualify import _apply_run_env

    monkeypatch.setenv("AGENTIC_DEB_TMP", "/mnt/big/tmp")
    monkeypatch.delenv("QUALIFY_NO_SEARXNG", raising=False)
    # Cleared explicitly: _apply_run_env writes to the PROCESS env (the tool reads it at import time), so an
    # earlier test in this process has already set it. What is under test is what it fills in when nothing is.
    monkeypatch.delenv("AGENTIC_CONFIGS_DIR", raising=False)
    _apply_run_env()
    assert os.environ["AGENTIC_DEB_TMP"] == "/mnt/big/tmp"
    assert os.environ["QUALIFY_NO_SEARXNG"] == "1"
    assert Path(os.environ["AGENTIC_CONFIGS_DIR"]).name == "configs"
