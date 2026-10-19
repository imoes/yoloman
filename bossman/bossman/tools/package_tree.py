"""An unpacked package of either family — the filesystem tree it would install, nothing installed.

One door for "what is in this package": the validator miner needs the BINARIES and their man1/man8 pages, which
neither _deb_config (the config file) nor rpm_source's callers (the config file) ask for.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from contextlib import contextmanager
from pathlib import Path

from bossman.tools import qualify_packages as Q
from bossman.tools import rpm_source

BIN_DIRS = ("usr/sbin", "usr/bin", "sbin", "bin", "usr/libexec")


@contextmanager
def unpacked(family: str, pkg: str):
    """Yield the root of the unpacked package, or None when it cannot be fetched. Always cleaned up."""
    if family == "redhat":
        tree = rpm_source.fetch(pkg)
        try:
            yield tree.root if tree.ok else None
        finally:
            tree.cleanup()
        return
    work = None
    try:
        if not Q._ensure_debian_apt():
            yield None
            return
        work = Path(tempfile.mkdtemp(dir=str(Q.DEB_TMP)))
        subprocess.run(["apt-get", *Q._apt_opts(), "download", pkg], cwd=str(work),
                       capture_output=True, timeout=180)
        debs = list(work.glob("*.deb"))
        if not debs:
            yield None
            return
        root = work / "root"
        subprocess.run(["dpkg-deb", "-x", str(debs[0]), str(root)], capture_output=True, timeout=180)
        yield root
    finally:
        if work:
            shutil.rmtree(work, ignore_errors=True)


def binaries(root: Path) -> list[str]:
    """Executables the package ships, as absolute paths."""
    out = []
    for d in BIN_DIRS:
        top = root / d
        if top.is_dir():
            for f in sorted(top.iterdir()):
                if f.is_file() and os.access(f, os.X_OK):
                    out.append("/" + str(f.relative_to(root)))
    return out


def man_pages(root: Path, sections: tuple[str, ...] = ("1", "8")) -> dict[str, str]:
    """Rendered man pages of the given sections the package ships: page stem -> text."""
    env = {**os.environ, "MANWIDTH": "100", "MANPAGER": "cat", "PAGER": "cat"}
    out: dict[str, str] = {}
    for sec in sections:
        mandir = root / f"usr/share/man/man{sec}"
        if not mandir.is_dir():
            continue
        for page in sorted(mandir.iterdir()):
            if not page.is_file():
                continue
            try:
                txt = subprocess.run(["man", "-l", str(page)], capture_output=True, text=True,
                                     env=env, timeout=60).stdout
            except (OSError, subprocess.SubprocessError):
                continue
            if txt.strip():
                out[page.name.split(f".{sec}")[0]] = txt[:200000]
    return out
