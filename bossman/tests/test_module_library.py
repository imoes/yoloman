"""Tests for services/module_library.py — the Starlark module library
behind the Block-G8 MCP tools. No database needed: the library is pure
filesystem + one subprocess. The real Go validator is built once per test
session from the repo's own cmd/starlark-check (no mocked validation —
the same binary production uses); tests skip if no Go toolchain is
available, mirroring conftest.py's "skip, don't mock" discipline.
"""

import json
import shutil
import subprocess
from pathlib import Path

import pytest

from bossman.services import module_library

REPO_ROOT = Path(__file__).resolve().parents[2]

VALID_STAR = """\
def main(ctx, params):
    name = params.get("name", "nginx")
    res = ctx.run(["systemctl", "is-active", name])
    if res.rc == 0:
        return {"changed": False, "msg": name + " already active"}
    start = ctx.run(["systemctl", "start", name], mutates=True)
    if start.skipped:
        return {"changed": True, "msg": "would start " + name}
    return {"changed": True, "msg": "started " + name}
"""

VALID_METADATA = """\
name: demo_service
fqcn: community.general.demo_service
collection: community.general
short_description: manage the demo service
options:
  name: {type: str, required: true, description: service name}
writes: true
runtime: starlark
source: translated
"""


@pytest.fixture(scope="session")
def starlark_check(tmp_path_factory) -> str:
    """Builds the real validator binary from the repo — the identical code
    path production uses (module_library shells out to it)."""
    if shutil.which("go") is None:
        pytest.skip("no Go toolchain available to build starlark-check")
    out = tmp_path_factory.mktemp("bin") / "starlark-check"
    build = subprocess.run(
        ["go", "build", "-o", str(out), "./cmd/starlark-check"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    if build.returncode != 0:
        pytest.fail(f"go build failed: {build.stderr}")
    return str(out)


def test_validate_star_valid_module(starlark_check):
    result = module_library.validate_star(starlark_check, VALID_STAR, {"name": "nginx"})
    assert result.ok
    assert result.stub_ok
    assert any("is-active" in c for c in result.calls)


def test_validate_star_reports_parse_error(starlark_check):
    result = module_library.validate_star(starlark_check, "def main(ctx, params)\n    return {}\n")
    assert not result.ok
    assert result.errors and result.errors[0]["stage"] == "parse"


def test_validate_star_missing_binary_raises():
    with pytest.raises(module_library.ModuleLibraryError, match="not found"):
        module_library.validate_star("/nonexistent/starlark-check", VALID_STAR)


def test_parse_metadata_valid():
    meta = module_library.parse_metadata(VALID_METADATA)
    assert meta["fqcn"] == "community.general.demo_service"


@pytest.mark.parametrize(
    ("mutation", "match"),
    [
        (lambda y: y.replace("runtime: starlark", "runtime: python"), "runtime"),
        (lambda y: y.replace("fqcn: community.general.demo_service", "fqcn: community.general.other"), "does not match"),
        (lambda y: y.replace("writes: true\n", ""), "missing required keys"),
        (lambda y: "[not, a, mapping]", "mapping"),
    ],
)
def test_parse_metadata_rejects_bad_input(mutation, match):
    with pytest.raises(module_library.ModuleLibraryError, match=match):
        module_library.parse_metadata(mutation(VALID_METADATA))


def test_submit_stores_valid_module(starlark_check, tmp_path):
    modules_dir = tmp_path / "modules.d"
    result = module_library.submit(
        modules_dir, starlark_check, "community.general.demo_service", VALID_METADATA, VALID_STAR, {"name": "x"}
    )
    assert result["stored"] is True
    yaml_path = modules_dir / "community.general" / "demo_service.yaml"
    star_path = modules_dir / "community.general" / "demo_service.star"
    assert yaml_path.exists() and star_path.exists()
    assert star_path.read_text() == VALID_STAR


def test_submit_rejects_invalid_star_without_storing(starlark_check, tmp_path):
    modules_dir = tmp_path / "modules.d"
    result = module_library.submit(
        modules_dir, starlark_check, "community.general.demo_service", VALID_METADATA, "def helper():\n    pass\n"
    )
    assert result["stored"] is False
    assert result["validation"]["errors"]
    assert not (modules_dir / "community.general" / "demo_service.star").exists()


def test_submit_rejects_fqcn_mismatch(starlark_check, tmp_path):
    with pytest.raises(module_library.ModuleLibraryError, match="does not match metadata"):
        module_library.submit(tmp_path, starlark_check, "community.general.wrong", VALID_METADATA, VALID_STAR)


def test_load_source_and_status(tmp_path):
    sources = tmp_path / "module_sources"
    sources.mkdir()
    for fqcn in ["ansible.posix.sysctl", "community.general.timezone"]:
        (sources / f"{fqcn}.json").write_text(json.dumps({"fqcn": fqcn, "source_py": "..."}))

    loaded = module_library.load_source(sources, "ansible.posix.sysctl")
    assert loaded["fqcn"] == "ansible.posix.sysctl"
    with pytest.raises(module_library.ModuleLibraryError, match="no dumped source"):
        module_library.load_source(sources, "community.general.nope")

    # One of the two translated → status counts it and lists the other.
    modules_dir = tmp_path / "modules.d"
    (modules_dir / "ansible.posix").mkdir(parents=True)
    (modules_dir / "ansible.posix" / "sysctl.yaml").write_text("x")
    (modules_dir / "ansible.posix" / "sysctl.star").write_text("y")
    st = module_library.status(modules_dir, sources)
    assert st["total"] == 2
    assert st["translated"] == 1
    assert st["collections"]["community.general"]["missing"] == ["community.general.timezone"]


def test_contract_documents_the_full_ctx_api():
    """The contract markdown is the LLM's only documentation — a missing
    builtin there means garbage modules, so pin the API surface."""
    for needle in [
        "def main(ctx, params):",
        "ctx.check_mode",
        "ctx.run(argv",
        "ctx.file_read",
        "ctx.file_write",
        "ctx.file_exists",
        "ctx.stat",
        "ctx.facts()",
        '{"changed": bool, "msg": str}',
        "fail(",
        "runtime: starlark",
    ]:
        assert needle in module_library.CONTRACT_MARKDOWN, f"contract is missing: {needle}"
