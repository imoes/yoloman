"""configs/package_validators.json has TWO writers: the LLM miner (mine_package_validators) proposes checkers, the
probe (probe_checkers) decides them on a test host. Both used to load the file once and write their whole copy back,
so each erased the other: measured 2026-10-16, the miner — started before a probe run — rewrote 69 probe decisions
(verified/rejected) back into unverified guesses with its stale copy, and the commit after it carried the damage.

Every write goes through `update`: under an exclusive lock it reloads the file, applies ONE change and writes it back
atomically. A writer changes only the entries it means to.
"""

from __future__ import annotations

import contextlib
import fcntl
import json
from collections.abc import Callable, Iterator
from pathlib import Path

from bossman.tools._jsonio import write_catalog
from bossman.tools._paths import configs_dir

PATH = configs_dir(__file__) / "package_validators.json"


def decided(entry: dict | None) -> bool:
    """A probe has judged this entry on a test host (verified or rejected) — no model guess may replace it."""
    if not isinstance(entry, dict):
        return False
    return (str(entry.get("source") or "").startswith(("verified", "rejected"))
            or entry.get("status") == "rejected")


@contextlib.contextmanager
def _locked(path: Path) -> Iterator[None]:
    with open(path.with_name(path.name + ".lock"), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def load(path: Path = PATH) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def update(change: Callable[[dict], None], path: Path = PATH) -> dict:
    """Reload, apply `change` to the fresh document, write it back atomically — all under one lock."""
    with _locked(path):
        doc = load(path)
        change(doc)
        write_catalog(path, doc, sort=True)      # atomic, the one catalog format
        return doc
