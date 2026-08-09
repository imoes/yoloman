"""F-8 — the config codec registry as a read-only catalog. Serves
configs/config_codecs.json (the man-page-derived registry, also go:embedded in
the agent) so an operator can see how each config file's grammar is read and
written: which codec (keyvalue/ini/xml/toml/…), the comment/separator syntax,
how confident the classification is, and which paths/packages it covers.

Read-only by design — the registry is generated offline by
scripts/classify_config_codecs.py; this endpoint just makes it visible next to
the config-templates catalog (which had a UI while codecs didn't)."""

from __future__ import annotations

import json
from pathlib import Path

from fastapi import APIRouter, Depends

from bossman.api.auth import get_current_identity
from bossman.config import Settings, get_settings

router = APIRouter()


@router.get("/api/v1/config-codecs")
async def list_config_codecs(
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
) -> dict:
    """The whole codec registry as a flat list, one entry per pattern:
    [{pattern, codec, confidence, comment, separator, notes, sections,
    paths, packages}]. Also a `summary` with per-codec / per-confidence
    counts so the UI can show catalog stats without re-counting."""
    path = Path(settings.config_codecs_path)
    if not path.is_file():
        return {"entries": [], "summary": {"total": 0, "by_codec": {}, "by_confidence": {}}, "available": False}

    try:
        raw = json.loads(path.read_text())
    except (ValueError, OSError):
        return {"entries": [], "summary": {"total": 0, "by_codec": {}, "by_confidence": {}}, "available": False}

    entries: list[dict] = []
    by_codec: dict[str, int] = {}
    by_confidence: dict[str, int] = {}
    for pattern, spec in raw.items():
        if not isinstance(spec, dict):
            continue
        codec = spec.get("codec") or "none"
        confidence = spec.get("confidence") or "unknown"
        by_codec[codec] = by_codec.get(codec, 0) + 1
        by_confidence[confidence] = by_confidence.get(confidence, 0) + 1
        entries.append({
            "pattern": pattern,
            "codec": codec,
            "confidence": confidence,
            "comment": spec.get("comment") or "",
            "separator": spec.get("separator") or "",
            "notes": spec.get("notes") or "",
            "sections": bool(spec.get("sections")),
            "paths": spec.get("paths") or [],
            "packages": spec.get("packages") or [],
        })

    # Stable order: by codec, then pattern — groups the catalog sensibly.
    entries.sort(key=lambda e: (e["codec"], e["pattern"]))
    return {
        "entries": entries,
        "summary": {"total": len(entries), "by_codec": by_codec, "by_confidence": by_confidence},
        "available": True,
    }
