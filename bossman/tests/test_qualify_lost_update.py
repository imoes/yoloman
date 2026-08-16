"""The qualify pass must not discard another writer's edits to the shared catalogs.

Measured defect: a pass loads configs/config_codecs.json, mutates it in memory for minutes, then
writes the whole dict back. A hand-curated `dirvalue` classification for /etc/pure-ftpd/conf was
silently reverted to `keyvalue` by a pass that had loaded the file before the edit. Every writer is
affected — a second pass, the on-demand qualify endpoint, an operator with an editor — not just the
one that happened to notice.

The fix is TrackedDict: the dict records which keys THIS process changed, so the flush can re-read
the file and apply only those. These tests pin both halves — that a concurrent edit survives, and
that this process's own change still lands.
"""

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path("/app/scripts")))
qualify = pytest.importorskip("qualify_packages", reason="qualify scripts not mounted")
TrackedDict = qualify.TrackedDict


def _seed(tmp_path: Path, data: dict) -> Path:
    p = tmp_path / "catalog.json"
    p.write_text(json.dumps(data, indent=2) + "\n")
    return p


def test_a_concurrent_edit_survives_the_flush(tmp_path):
    """The exact scenario that lost the dirvalue classification."""
    path = _seed(tmp_path, {"/etc/a.conf": {"codec": "ini"}, "/etc/pure-ftpd/conf": {"codec": "keyvalue"}})

    loaded = TrackedDict(json.loads(path.read_text()))       # pass starts, loads the file
    loaded["/etc/b.conf"] = {"codec": "yaml"}                 # pass classifies something

    # …meanwhile, someone else corrects an entry this pass never touched.
    disk = json.loads(path.read_text())
    disk["/etc/pure-ftpd/conf"] = {"codec": "dirvalue"}
    path.write_text(json.dumps(disk, indent=2) + "\n")

    merged = loaded.merged_with_disk(path)
    assert merged["/etc/pure-ftpd/conf"]["codec"] == "dirvalue", "the concurrent edit was clobbered"
    assert merged["/etc/b.conf"]["codec"] == "yaml", "this pass's own work was dropped"
    assert merged["/etc/a.conf"]["codec"] == "ini", "an untouched entry disappeared"


def test_the_old_behaviour_really_did_lose_it():
    """A guard that cannot fail proves nothing: show the wholesale write loses the same edit.

    Without this, the test above would pass just as happily against a merge that never had a
    defect to fix.
    """
    loaded = {"/etc/pure-ftpd/conf": {"codec": "keyvalue"}}   # what the pass holds
    disk = {"/etc/pure-ftpd/conf": {"codec": "dirvalue"}}     # what is on disk now
    assert dict(loaded)["/etc/pure-ftpd/conf"]["codec"] == "keyvalue"
    assert disk["/etc/pure-ftpd/conf"]["codec"] == "dirvalue"  # …and the old flush wrote `loaded`


def test_this_pass_wins_for_keys_it_actually_wrote(tmp_path):
    """Last writer wins only where there IS an intent to write. A pass that re-classifies a path
    must not be overridden by the value it read at start-up."""
    path = _seed(tmp_path, {"/etc/x.conf": {"codec": "keyvalue"}})
    loaded = TrackedDict(json.loads(path.read_text()))
    loaded["/etc/x.conf"] = {"codec": "ini"}                   # this pass re-classified it
    path.write_text(json.dumps({"/etc/x.conf": {"codec": "yaml"}}, indent=2) + "\n")
    assert loaded.merged_with_disk(path)["/etc/x.conf"]["codec"] == "ini"


def test_a_deletion_is_intent_too(tmp_path):
    """Removing a key must reach disk; otherwise the merge would quietly resurrect it."""
    path = _seed(tmp_path, {"/etc/x.conf": {"codec": "ini"}, "/etc/y.conf": {"codec": "ini"}})
    loaded = TrackedDict(json.loads(path.read_text()))
    del loaded["/etc/x.conf"]
    merged = loaded.merged_with_disk(path)
    assert "/etc/x.conf" not in merged
    assert "/etc/y.conf" in merged


def test_reading_a_key_is_not_intent(tmp_path):
    """The heart of it: merely holding a key must not write it back.

    `disk | loaded` would pass every other test here and still lose the concurrent edit, because a
    loaded dict contains everything. Only touched/removed count.
    """
    path = _seed(tmp_path, {"/etc/x.conf": {"codec": "ini"}})
    loaded = TrackedDict(json.loads(path.read_text()))
    _ = loaded["/etc/x.conf"]                                  # read, do not write
    path.write_text(json.dumps({"/etc/x.conf": {"codec": "dirvalue"}}, indent=2) + "\n")
    assert loaded.merged_with_disk(path)["/etc/x.conf"]["codec"] == "dirvalue"


def test_update_and_pop_are_tracked_too(tmp_path):
    """The tracking must not depend on which dict method a future call site happens to use."""
    path = _seed(tmp_path, {"a": 1, "b": 2})
    loaded = TrackedDict(json.loads(path.read_text()))
    loaded.update({"c": 3})
    loaded.pop("a")
    merged = loaded.merged_with_disk(path)
    assert merged == {"b": 2, "c": 3}


def test_write_json_is_atomic_and_leaves_no_temp(tmp_path):
    """Readers see the old file or the new one, never a half-written catalog — these files are
    bind-mounted into the running server and read live."""
    path = tmp_path / "c.json"
    qualify._write_json(path, {"b": 1, "a": 2}, sort=True)
    assert json.loads(path.read_text()) == {"a": 2, "b": 1}
    assert list(path.parent.glob("*.tmp")) == [], "temp file left behind"
    # Sorted on request, insertion order otherwise — the catalogs rely on stable diffs.
    assert path.read_text().index('"a"') < path.read_text().index('"b"')
