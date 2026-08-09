"""ADMX equivalent — the per-directive value catalog as a read-only lookup. Serves
configs/config_directives.json (mined by scripts/mine_directive_values.py from
config man pages) so the gpedit editor can render a real per-directive control:
an enum's exact allowed values (PermitRootLogin -> yes/no/prohibit-password/
forced-commands-only), a bool toggle, or an int with min/max — instead of
guessing a yes/no family from the current value.

Keyed like the codec registry (config file / pattern), one level deeper: each
file maps directive name -> {type, values?, default?, min?, max?, description?}.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Depends

from bossman.api.auth import get_current_identity
from bossman.config import Settings, get_settings

router = APIRouter()


@router.get("/api/v1/config-directives")
async def config_directives(
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """The whole directive-value catalog: {file: {directive: spec}}. Empty
    (available:false) until the mining batch has produced the file."""
    path = Path(settings.config_directives_path)
    if not path.is_file():
        return {"directives": {}, "available": False}
    try:
        data = json.loads(path.read_text())
    except (ValueError, OSError):
        return {"directives": {}, "available": False}
    if not isinstance(data, dict):
        return {"directives": {}, "available": False}
    return {"directives": data, "available": True}
