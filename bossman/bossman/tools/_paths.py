"""Where is the repository root, and where is configs/ — found, not counted.

Every tool in this package used `Path(__file__).resolve().parents[2]`, and that constant is only right in one
of the two layouts these tools run in:

    the container   /app/bossman/tools/x.py            parents[2] == /app                      correct
    the repo        …/yolo-man/bossman/bossman/tools/x.py  parents[2] == …/yolo-man/bossman     ONE SHORT

So run from a checkout they looked for `bossman/configs/config_templates`, which does not exist, and died in
`iterdir()`. That is exactly why a second copy of each tool still sat in `bossman/scripts/` with the constant
patched to `parents[1]` — two files, one line apart, and the batch service ran the copy while the product
imported the original. A refactor in one was invisible to the other.

Counting directories encodes the layout in a number. Searching for the thing that is actually wanted does
not: the root is the nearest ancestor that HAS a `configs/` directory. Both layouts answer correctly, and a
third would too.

AGENTIC_CONFIGS_DIR still wins where it is set — the container passes it, and a caller pointing the pipeline
at a different catalog is a legitimate thing to do, not a fallback.
"""

from __future__ import annotations

import os
from pathlib import Path

_MARKER = "configs"

#: What makes a configs/ THE catalog rather than a directory that happens to be called configs. Measured
#: need: `bossman/configs/` exists in this checkout — root-owned empty dirs a container bind-mount left
#: behind — and a plain "is there a configs/ dir" test picked it, so the pipeline looked for
#: bossman/configs/config_templates and died in iterdir(). Any ONE of these is enough: a fresh catalog
#: directory may hold the codecs before the templates, or the reverse.
_CATALOG_SIGNS = ("config_codecs.json", "config_templates", "package_catalog.json")


def repo_root(start: str | Path | None = None) -> Path:
    """The nearest ancestor of `start` (default: this file) whose configs/ actually holds a catalog.

    Falls back to the old parents[2] behaviour if nothing matches, so a layout this does not anticipate gets
    the previous answer rather than an exception at import time — a tool that cannot be imported cannot even
    report what went wrong.
    """
    here = Path(start or __file__).resolve()
    for candidate in here.parents:
        cfg = candidate / _MARKER
        if cfg.is_dir() and any((cfg / sign).exists() for sign in _CATALOG_SIGNS):
            return candidate
    return here.parents[2] if len(here.parents) > 2 else here.parent


def configs_dir(start: str | Path | None = None) -> Path:
    """The catalog directory: AGENTIC_CONFIGS_DIR when set, else <repo root>/configs."""
    override = os.environ.get("AGENTIC_CONFIGS_DIR", "").strip()
    return Path(override) if override else repo_root(start) / _MARKER
