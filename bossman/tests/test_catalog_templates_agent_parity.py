"""Every catalog role's template renders the same under the agent's renderer (gonja, via render-check) as under
the jinja2 the pipeline checks with — with the values the engine really hands over (defaults, dotted → nested).

Why: the pipeline validated templates with jinja2 while the agent wrote with gonja. Measured 2026-10-10 over all
templates: `true | int` was 0 under gonja (acmesh AUTO_RENEW="0"), `quote` quoted every word, backup2l's
list.append() did nothing (SKIPCOND=() on every host). A template that renders differently was checked as one
thing and written as another. Tolerated: float formatting (gonja writes 1.0 as 1) and whitespace.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest

from bossman.services.nt_engine import _nest_dotted
from bossman.services.schema_defaults import schema_defaults
from bossman.tools.template_invariants import _env

CONFIGS = Path(__file__).resolve().parents[2] / "configs"
KNOWN: dict[str, str] = {}   # named exceptions, each with its reason (mpd.conf's was fixed 2026-10-10)


@pytest.fixture(scope="module")
def render_check() -> str:
    env = os.environ.get("RENDER_CHECK_BIN")
    if env and Path(env).exists():
        return env
    if not shutil.which("go") and not Path("/usr/local/go/bin/go").exists():
        pytest.skip("no Go toolchain to build render-check")
    out = str(Path(tempfile.gettempdir()) / "render-check-parity")
    go = shutil.which("go") or "/usr/local/go/bin/go"
    subprocess.run([go, "build", "-o", out, "./cmd/render-check/"], cwd=CONFIGS.parent, check=True,
                   capture_output=True)
    return out


def _norm(text: str) -> str:
    # The same transformation on BOTH sides, so literal text (127.0.0.1, HTTP/1.0) is changed alike.
    return " ".join(re.sub(r"(\d+)\.0\b", r"\1", text).split())


def _same(a: str, b: str) -> bool:
    return a == b or _norm(a) == _norm(b)


def test_catalog_templates_render_the_same_for_the_agent(render_check):
    catalog = json.loads((CONFIGS / "package_catalog.json").read_text())
    names = sorted({e["template"] for e in catalog.values() if isinstance(e, dict) and e.get("template")})
    bad = []
    for name in names:
        d = CONFIGS / "config_templates" / name
        if name in KNOWN or not (d / "template.j2").is_file():
            continue
        body = (d / "template.j2").read_text(errors="replace")
        try:
            schema = json.loads((d / "schema.json").read_text())
            schema = schema.get("properties", schema) if isinstance(schema, dict) else {}
        except (OSError, ValueError):
            schema = {}
        values = _nest_dotted(schema_defaults(schema))
        try:
            expected = _env().from_string(body).render(**values)
        except Exception:  # noqa: BLE001 — the jinja side's failures are the template audit's business
            continue
        with tempfile.TemporaryDirectory() as td:
            (Path(td) / "t.j2").write_text(body)
            (Path(td) / "v.json").write_text(json.dumps(values, default=str))
            p = subprocess.run([render_check, "-template", f"{td}/t.j2", "-values", f"{td}/v.json"],
                               capture_output=True, text=True, timeout=30)
        if p.returncode != 0:
            bad.append(f"{name}: the agent cannot render it — {p.stderr.strip()[-160:]}")
        elif not _same(expected, p.stdout):
            first = next(((a, b) for a, b in zip(expected.splitlines(), p.stdout.splitlines()) if a != b), None)
            bad.append(f"{name}: jinja2 {first[0]!r} / agent {first[1]!r}" if first else f"{name}: length differs")
    assert not bad, "\n".join(bad)
