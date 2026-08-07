"""On-demand package qualification — the "create all config files for a package"
endpoint (Block: new-package pipeline).

Runs the SAME qualify pipeline the host batch runs (`scripts/qualify_packages.py`
→ codec, directives, template, enum), then rebuilds the catalog
(`scripts/build_package_catalog.py`) so the package is CATEGORIZED (einsortiert)
the same way — the category lives in the catalog builder, not the template stage.

Both scripts run in-process-adjacent via a subprocess using the app's own venv,
against the RW-mounted configs (AGENTIC_CONFIGS_DIR=/app/configs), and use
Bossman's CONFIGURED AI endpoint (settings.hermes_web_*) — never a hardwired URL.
"""

from __future__ import annotations

import asyncio
import os
import sys
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from bossman.api.auth import get_current_identity
from bossman.config import get_settings

router = APIRouter()

# Repo root inside the container: this file is /app/bossman/api/package_qualify.py,
# so parents[2] == /app, which holds scripts/ and the RW-mounted configs/.
_APP_ROOT = Path(__file__).resolve().parents[2]
_CONFIGS_DIR = _APP_ROOT / "configs"
_SCRIPTS = _APP_ROOT / "scripts"


class QualifyResult(BaseModel):
    package: str
    ok: bool
    template_created: bool
    category: str | None
    codec: str | None
    directives_keys: int
    log_tail: str


def _run_env(settings) -> dict:
    """Env for the qualify subprocess: point the scripts at the RW configs and at
    Bossman's configured LLM endpoint (not the script's baked-in preset)."""
    env = {**os.environ, "AGENTIC_CONFIGS_DIR": str(_CONFIGS_DIR)}
    # Ground docs on the man page (local → the two public mirrors man7.org /
    # manpages.debian.org) + the shipped .deb, NOT the SearXNG metasearch (its
    # instance may be unreachable from the container). The two URLs are plain HTTP.
    env["QUALIFY_NO_SEARXNG"] = "1"
    # The .deb extraction path (shipped config + man page — how a package that
    # ships its own docs is covered) needs a writable tmp; the host default
    # (/data1/…) doesn't exist in the container.
    env.setdefault("AGENTIC_DEB_TMP", "/tmp/agentic-deb")
    # RENDER_CHECK_BIN is baked into the image (Dockerfile) so the enum-enrich
    # gate needs no `go` here — inherited via os.environ above.
    if settings.hermes_web_base_url and settings.hermes_web_model:
        env["QUALIFY_LLM_URL"] = settings.hermes_web_base_url
        env["QUALIFY_LLM_MODEL"] = settings.hermes_web_model
        if settings.hermes_web_token:
            env["QUALIFY_LLM_TOKEN"] = settings.hermes_web_token
    return env


async def _run(cmd: list[str], env: dict, timeout: float) -> tuple[int, str]:
    proc = await asyncio.create_subprocess_exec(
        *cmd, cwd=str(_APP_ROOT), env=env,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
    )
    try:
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        proc.kill()
        raise HTTPException(status_code=504, detail=f"qualify timed out after {int(timeout)}s")
    return proc.returncode or 0, (out or b"").decode(errors="replace")


def _catalog_category(name: str) -> str | None:
    import json

    cat_file = _CONFIGS_DIR / "package_catalog.json"
    try:
        data = json.loads(cat_file.read_text())
    except (OSError, ValueError):
        return None
    entry = data.get(name) if isinstance(data, dict) else None
    return entry.get("category") if isinstance(entry, dict) else None


async def run_qualify(name: str) -> QualifyResult:
    """Create every config artifact for one package (codec / directives / template
    / enum) via the qualify pipeline, then categorize it via the catalog builder.
    Shared by the REST endpoint and the MCP tool. Synchronous — a single package
    is normally a couple of minutes; the caller waits."""
    name = name.strip()
    if not name or "/" in name or ".." in name:
        raise HTTPException(status_code=422, detail="invalid package name")
    if not (_SCRIPTS / "qualify_packages.py").exists():
        raise HTTPException(status_code=500, detail="qualify scripts not available in this deployment")
    settings = get_settings()
    env = _run_env(settings)

    # 1) The full per-package pipeline (codec → directives → template → enum).
    rc, log = await _run(
        [sys.executable, "-u", "scripts/qualify_packages.py", "--only", name, "--concurrency", "1"],
        env, timeout=900.0,
    )
    # 2) Categorize / sort into the catalog (this is where "einsortiert" happens).
    _rc2, log2 = await _run([sys.executable, "-u", "scripts/build_package_catalog.py"], env, timeout=300.0)

    tdir = _CONFIGS_DIR / "config_templates" / name
    template_created = (tdir / "template.j2").exists() or (tdir / "schema.json").exists()

    # Report codec + directive coverage for the package's config path(s).
    codec = None
    directives_keys = 0
    try:
        import json

        codecs = json.loads((_CONFIGS_DIR / "config_codecs.json").read_text())
        pkgs = codecs.get("packages", {}) if isinstance(codecs, dict) else {}
        pkg = pkgs.get(name)
        if isinstance(pkg, dict):
            codec = pkg.get("codec")
        directives = json.loads((_CONFIGS_DIR / "config_directives.json").read_text())
        if isinstance(pkg, dict):
            for p in (pkg.get("paths") or []):
                if p in directives and isinstance(directives[p], dict):
                    directives_keys += len(directives[p])
    except (OSError, ValueError):
        pass

    tail = "\n".join((log + log2).splitlines()[-40:])
    return QualifyResult(
        package=name, ok=(rc == 0), template_created=template_created,
        category=_catalog_category(name), codec=codec, directives_keys=directives_keys,
        log_tail=tail,
    )


@router.post("/api/v1/packages/{name}/qualify", response_model=QualifyResult)
async def qualify_package(
    name: str,
    _identity=Depends(get_current_identity),
) -> QualifyResult:
    """Create every config artifact for one package (codec/directives/template/enum)
    + categorize it. Runs the same qualify pipeline the host batch uses."""
    return await run_qualify(name)
