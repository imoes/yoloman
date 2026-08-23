"""One writer for the shared config catalogs, so a diff means a change.

`configs/config_codecs.json` and `configs/config_directives.json` are written by ~17 different places — the
packaged pipeline, and a dozen local recording and repair scripts. They did not agree on how:

    the pipeline's _write_json      indent=2, ensure_ascii=True   (default)
    every recording script          indent=1, ensure_ascii=False

Both axes rewrite the WHOLE file, so the two groups took turns reformatting 200 000 lines. Measured on the
committed files: 615 + 1351 `\\uXXXX` escapes and zero raw non-ASCII bytes, i.e. the last writer was the
ensure_ascii=True one — and the next script to touch a single key would have unescaped all 1966 of them. A
one-key change and a reformat produce the same diff, which means a real change to these catalogs cannot be
reviewed, and a wrong one cannot be spotted.

THE CHOICE, and why each half:

    indent=2         what the product-side writer already used, so the committed files stay as they are
    ensure_ascii=False   these values are man-page derived prose. `\\u2019` is not readable, and a catalog
                     nobody can read is a catalog nobody checks. Costs one reformat, once.
    sort_keys=True   a stable order, or every insertion moves unrelated lines

ATOMIC, because these files are shared between a batch that runs for minutes, the on-demand qualify endpoint
and an operator: a reader that opens a half-written catalog gets a JSON error, and the callers treat an
unparsable catalog as an EMPTY one. Write to a temp file in the same directory, then os.replace().
"""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path

#: The format. Named rather than inlined at each call, so "what does a catalog look like" has one answer.
INDENT = 2
ENSURE_ASCII = False


def dumps_catalog(data, *, sort: bool = True) -> str:
    """The canonical serialisation, for a caller that needs the text rather than a file."""
    return json.dumps(data, indent=INDENT, sort_keys=sort, ensure_ascii=ENSURE_ASCII) + "\n"


def write_catalog(path: str | Path, data, *, sort: bool = True) -> None:
    """Write a shared catalog atomically, in the one format.

    Same directory for the temp file: os.replace() is only atomic within a filesystem, and /tmp is very often
    a different one — the rename would fall back to a copy, which is exactly the torn read this avoids.
    """
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    # THE EXISTING FILE'S MODE, carried over. mkstemp creates 0600, and os.replace() replaces the mode along
    # with the contents — so writing from the container (root) left these catalogs root-only, and the host
    # user could not even md5sum them. A shared, bind-mounted file that one writer can silently make private
    # is worse than a torn read: the batch keeps working and every other reader goes blind.
    owner: tuple[int, int] | None = None
    try:
        st = os.stat(path)
        mode = st.st_mode & 0o777
        owner = (st.st_uid, st.st_gid)
    except OSError:
        mode = 0o644 & ~_umask()
    fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.", suffix=".tmp")
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(dumps_catalog(data, sort=sort))
        os.chmod(tmp, mode)
        # AND THE OWNER, when we are allowed to set it. These catalogs are bind-mounted and written by two
        # different identities: the container (root) and the host batch (the developer's uid). Whoever wrote
        # last used to become the owner, so a write from the container left a root-owned file the host batch
        # could no longer update — a shared file must not change hands because of who happened to touch it.
        # Best-effort: an unprivileged writer simply keeps its own ownership, which is the status quo.
        if owner is not None:
            try:
                os.chown(tmp, owner[0], owner[1])
            except (OSError, AttributeError):
                pass
        os.replace(tmp, path)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise


def _umask() -> int:
    """The process umask, read without leaving it changed. There is no getter, only the setter."""
    current = os.umask(0o022)
    os.umask(current)
    return current
