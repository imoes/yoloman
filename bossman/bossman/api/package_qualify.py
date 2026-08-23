"""On-demand package qualification — the "create all config files for a package"
endpoint (Block: new-package pipeline).

Runs the SAME pipeline the host batch runs (`bossman.tools.qualify_packages` → codec, directives, template,
enum), then rebuilds the catalog (`bossman.tools.build_package_catalog`) so the package is CATEGORIZED
(einsortiert) the same way — the category lives in the catalog builder, not the template stage.

IN THIS PROCESS, not in a subprocess. It used to spawn `python -m bossman.tools.qualify_packages --only
<name>` and rebuild the answer from a 40-line log tail plus a re-read of the config files. Three things were
wrong with that, and only the third is about cost:

  1. THE ENDPOINT WAS DEAD. It guarded on `/app/scripts/qualify_packages.py`, a path that stopped existing
     when the tools moved into the package — so every call returned 500 "qualify scripts not available in
     this deployment". A guard for a file nobody runs is worse than no guard: it fails the working thing.
  2. IT REPORTED THE WRONG ANSWER. `codec` and `directives_keys` came from `codecs.get("packages", {})`, and
     config_codecs.json has no top-level "packages" key — it is keyed by PATH, each entry carrying a
     `packages` list. So `codec` was always null and `directives_keys` always 0, including for the package
     whose codec the run had just classified. Now the values come from `process_package`'s own return, which
     had them all along; the file is consulted only for a package that was ALREADY current.
  3. And an interpreter start plus a full re-import of the pipeline per request, to reach a coroutine this
     process can await.

The LLM endpoint stays CONFIGURABLE — Bossman's own `settings.hermes_web_*`, never a hardwired URL.
"""

from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from bossman.api.auth import get_current_identity
from bossman.config import get_settings

router = APIRouter()

# Repo root inside the container: this file is /app/bossman/api/package_qualify.py,
# so parents[2] == /app, which holds the RW-mounted configs/.
_APP_ROOT = Path(__file__).resolve().parents[2]
_CONFIGS_DIR = _APP_ROOT / "configs"


class QualifyResult(BaseModel):
    package: str
    ok: bool
    #: True when every marker was already at the current pipeline version, so NOTHING ran. Distinguishing
    #: this from a fresh build is the whole reason it is a field: both leave a template on disk, and the
    #: caller of "qualify this package" deserves to know which one it got. `force` asks for the rebuild.
    already_current: bool
    template_created: bool
    category: str | None
    codec: str | None
    directives_keys: int
    #: What the run itself reported — enums mined, whether the Lego enrich gates passed, and the reason a
    #: package was skipped or failed. Straight from process_package rather than parsed out of its log.
    status: str
    enums: int
    directives_mined: int
    enriched: bool
    #: The reason, whichever kind applies: why a package was skipped, which LLM step could not be reached,
    #: or which enrich gate stopped the Lego artifacts. `ok: false` without a ground is a refusal that does
    #: not say why.
    detail: str | None

    # NO log_tail. It carried the last 40 lines of the subprocess's stdout; run in-process, the pipeline's
    # prints go to Bossman's own log, where a pass that takes minutes belongs and where they are not
    # truncated to 40 lines. An always-empty field would state "nothing was logged", which is false.


def _apply_run_env() -> None:
    """Point the pipeline at the RW configs and at sources reachable from the container.

    Set on os.environ rather than passed: the tool module reads these at IMPORT time (`_CONFIGS`,
    `DEB_TMP`), which is a property of the module this endpoint no longer gets to choose by spawning a
    process with a custom env. setdefault throughout, so a deployment that configured one of these keeps it.
    """
    os.environ.setdefault("AGENTIC_CONFIGS_DIR", str(_CONFIGS_DIR))
    # Ground docs on the man page (local → the public mirrors man7.org / manpages.debian.org) + the shipped
    # .deb, NOT the SearXNG metasearch: its instance may be unreachable from the container.
    os.environ.setdefault("QUALIFY_NO_SEARXNG", "1")
    # The .deb extraction path needs a writable tmp; the host default (/data1/…) is not in the container.
    os.environ.setdefault("AGENTIC_DEB_TMP", "/tmp/agentic-deb")


def _catalog_category(name: str) -> str | None:
    try:
        data = json.loads((_CONFIGS_DIR / "package_catalog.json").read_text())
    except (OSError, ValueError):
        return None
    entry = data.get(name) if isinstance(data, dict) else None
    return entry.get("category") if isinstance(entry, dict) else None


def _recorded_codec(name: str) -> tuple[str | None, int]:
    """(codec, directive keys) for a package, read the way config_codecs.json is actually SHAPED.

    Keyed by path; each entry carries the packages that ship it. Only needed for an already-current package
    — a run that did the work returns its own answer, and re-deriving it from files would be a second way to
    compute the same thing.
    """
    try:
        codecs = json.loads((_CONFIGS_DIR / "config_codecs.json").read_text())
        directives = json.loads((_CONFIGS_DIR / "config_directives.json").read_text())
    except (OSError, ValueError):
        return None, 0
    if not isinstance(codecs, dict):
        return None, 0
    codec: str | None = None
    # A SET of paths, counted once at the end. An entry's key is usually repeated inside its own `paths`
    # list, so summing per-occurrence counted /etc/nginx/nginx.conf's two directives as four — a plausible
    # number, which is the kind that goes unnoticed.
    paths: set[str] = set()
    for path, entry in codecs.items():
        if not isinstance(entry, dict) or name not in (entry.get("packages") or []):
            continue
        # The FIRST real codec wins, not the last: a package can own several files and a later `none`
        # would erase the answer the earlier one gave.
        if codec in (None, "none") and entry.get("codec"):
            codec = entry["codec"]
        paths.add(path)
        paths.update(p for p in (entry.get("paths") or []) if isinstance(p, str))
    if not isinstance(directives, dict):
        return codec, 0
    return codec, sum(len(directives[p]) for p in paths
                      if isinstance(directives.get(p), dict))


async def run_qualify(name: str, *, force: bool = False) -> QualifyResult:
    """Create every config artifact for one package (codec / directives / template / enum) via the qualify
    pipeline, then categorize it via the catalog builder. Shared by the REST endpoint and the MCP tool.
    Synchronous — a single package is normally a couple of minutes; the caller waits."""
    name = name.strip()
    if not name or "/" in name or ".." in name:
        raise HTTPException(status_code=422, detail="invalid package name")
    _apply_run_env()
    # Imported HERE, not at module scope: the tool reads AGENTIC_CONFIGS_DIR at import time, and importing
    # it before _apply_run_env() would bind the pipeline to the wrong configs directory for the life of the
    # process. It also keeps app startup free of the pipeline's own import cost.
    from bossman.tools import build_package_catalog
    from bossman.tools.qualify_packages import qualify_one

    settings = get_settings()
    # Bossman's configured backend when it has one; qualify_one falls back to its own preset when it does
    # not, which is the pre-existing behaviour and worth knowing: an unconfigured Bossman talks to the batch
    # host's endpoint, not to nothing.
    try:
        result = await qualify_one(
            name,
            llm_url=settings.hermes_web_base_url or "",
            llm_model=settings.hermes_web_model or "",
            llm_token=settings.hermes_web_token or "",
            force=force,
        )
    except asyncio.TimeoutError as exc:
        raise HTTPException(status_code=504, detail=f"qualify timed out: {exc}") from exc

    # Categorize / sort into the catalog — this is where "einsortiert" happens. Skipped when nothing ran:
    # rebuilding the whole catalog to record a change that did not happen is work for no reason. Blocking
    # (it walks the template tree), so off the event loop.
    if not result.get("already_current"):
        await asyncio.to_thread(build_package_catalog.main)

    tdir = _CONFIGS_DIR / "config_templates" / name
    template_created = (tdir / "template.j2").exists() or (tdir / "schema.json").exists()

    codec = result.get("codec")
    keys = int(result.get("directives") or 0)
    if result.get("already_current"):
        # Nothing ran, so there is no run to quote. The files are then the only source, and the caller is
        # told which case this is via already_current.
        codec, keys = _recorded_codec(name)

    status = str(result.get("status") or "ok")
    return QualifyResult(
        package=name,
        # "failed" means an LLM step could not be reached: the package is deliberately NOT marked done so a
        # later pass retries it. Reporting that as ok would make a retry look like a fresh failure.
        ok=status in ("ok", "skip") or bool(result.get("already_current")),
        already_current=bool(result.get("already_current")),
        template_created=template_created,
        category=_catalog_category(name),
        codec=codec,
        directives_keys=keys,
        status="already-current" if result.get("already_current") else status,
        enums=int(result.get("enums") or 0),
        directives_mined=int(result.get("directives") or 0),
        enriched=bool(result.get("enriched")),
        detail=(result.get("reason")
                or "; ".join(result.get("llm_errors") or [])
                or result.get("enrich_gate_fail")
                or None),
    )


@router.post("/api/v1/packages/{name}/qualify", response_model=QualifyResult)
async def qualify_package(
    name: str,
    force: bool = False,
    _identity=Depends(get_current_identity),
) -> QualifyResult:
    """Create every config artifact for one package (codec/directives/template/enum) + categorize it.
    Runs the same qualify pipeline the host batch uses. `force=true` clears this package's markers first,
    so an already-qualified package is rebuilt instead of reported as already current."""
    return await run_qualify(name, force=force)
