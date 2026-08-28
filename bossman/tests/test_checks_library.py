"""Block G9 P1 — the flat check library (submit/list/load/status). Uses the
real Go starlark-check validator (repo bin/), same as the agent runtime."""

from pathlib import Path

import pytest

from bossman.services import checks_library
from bossman.services.module_library import ModuleLibraryError

# The statically-built validator in the repo (mounted into the container too).
_VALIDATOR = str(Path(__file__).resolve().parents[2] / "bin" / "starlark-check")

_GOOD_CHECK = """\
def main(ctx, params):
    path = params.get("path", "/etc/hostname")
    st = ctx.stat(path)
    if st == None or not st.get("exists"):
        return {"changed": False, "msg": "missing", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    size = st.get("size", 0)
    state = "OK"
    crit = params.get("size_crit")
    if crit != None and size >= crit:
        state = "CRIT"
    return {"changed": False, "msg": "Size: %d" % size, "data": {"state": state, "metrics": {"size": size}, "details": ""}}
"""

_META = """\
name: probe_size
short_description: on-host file size check
options:
  path:
    type: str
    description: file to probe
  size_crit:
    type: int
    description: crit level in bytes
writes: false
runtime: starlark
source: custom
kind: check
"""


def _skip_if_no_validator():
    if not Path(_VALIDATOR).exists():
        pytest.skip(f"no starlark-check validator at {_VALIDATOR}")


def test_submit_list_load_and_status(tmp_path):
    _skip_if_no_validator()
    res = checks_library.submit_check(tmp_path, _VALIDATOR, "probe_size", _META, _GOOD_CHECK, {})
    assert res["stored"] is True, res
    assert (tmp_path / "probe_size.star").exists()
    # Sidecars are YAML now (they were NestedText); check_paths writes the .yaml.
    assert (tmp_path / "probe_size.yaml").exists()

    listing = checks_library.list_checks(tmp_path)
    assert [c["name"] for c in listing] == ["probe_size"]
    assert listing[0]["kind"] == "check"
    assert "path" in listing[0]["options"]

    loaded = checks_library.load_check(tmp_path, "probe_size")
    assert loaded["metadata"]["writes"] is False
    assert "def main(ctx, params)" in loaded["star_code"]

    status = checks_library.checks_status(tmp_path, ["probe_size", "fileinfo", "http"])
    assert status["total"] == 3
    assert status["translated"] == 1
    assert status["missing"] == ["fileinfo", "http"]


def test_metadata_name_mismatch_rejected(tmp_path):
    _skip_if_no_validator()
    with pytest.raises(ModuleLibraryError):
        checks_library.submit_check(tmp_path, _VALIDATOR, "other_name", _META, _GOOD_CHECK, {})


def test_clean_check_description_strips_translator_boilerplate():
    # Boilerplate-only descriptions become a clean sentence from the short desc.
    assert checks_library.clean_check_description(
        "Checkmk check 'lnx_if' (service: Interface %s), translated to a "
        "read-only on-host Starlark check module.",
        "Interface %s",
    ) == "Monitors Interface on this host."
    # The newer "Monitoring check … read-only on-host Starlark check." variant too.
    assert checks_library.clean_check_description(
        "Monitoring check 'foo' (service: Pressure %s) — read-only on-host Starlark check.",
        "Pressure %s",
    ) == "Monitors Pressure on this host."
    # A real description (no boilerplate) is returned verbatim, period intact.
    real = "Aggregate health of ALL systemd service units. It reports Failed counts."
    assert checks_library.clean_check_description(real, "Systemd Service Summary") == real
    # No description at all → a sentence from the short description.
    assert checks_library.clean_check_description("", "Uptime") == "Monitors Uptime on this host."


def test_invalid_star_not_stored(tmp_path):
    _skip_if_no_validator()
    # Wrong main() arity is a hard parse+lint failure (`ok` false) — the
    # submit gate, unlike a non-dict return which only trips the stub run.
    bad = 'def main(ctx):\n    return {"changed": False, "msg": ""}\n'
    res = checks_library.submit_check(tmp_path, _VALIDATOR, "probe_size", _META, bad, {})
    assert res["stored"] is False
    assert not (tmp_path / "probe_size.star").exists()
