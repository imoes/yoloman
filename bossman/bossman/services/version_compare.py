"""Pure-Python package version comparators for CVE ↔ update correlation.

The CVE feeds give a "fixed_version"; to decide whether a host's pending
upgrade actually crosses that fix, we must compare package versions the way
the package manager does. Bossman has neither apt_pkg nor python-debian
(system-lib dependencies), so these mirror the canonical algorithms:

- ``dpkg_compare``     — Debian/Ubuntu, dpkg's ``verrevcmp`` over
  ``[epoch:]upstream[-revision]`` (lib/dpkg/version.c).
- ``rpm_evr_compare``  — RHEL family, rpm's ``rpmvercmp`` over
  ``[epoch:]version[-release]`` (lib/rpmvercmp.c).

Each returns -1 / 0 / 1 for a < b / a == b / a > b.
"""

from __future__ import annotations


# ---- Debian (dpkg) --------------------------------------------------------


def _dpkg_order(c: str) -> int:
    """Character ranking for the non-digit comparison (dpkg ``order``).

    ``~`` sorts before everything (even end-of-string), letters sort by their
    code point, every other character sorts after letters.
    """
    if c == "":
        return 0
    if c.isdigit():
        return 0
    if c.isalpha():
        return ord(c)
    if c == "~":
        return -1
    return ord(c) + 256


def _dpkg_verrevcmp(a: str, b: str) -> int:
    i, j = 0, 0
    la, lb = len(a), len(b)
    while i < la or j < lb:
        # Compare the leading non-digit run character by character.
        while (i < la and not a[i].isdigit()) or (j < lb and not b[j].isdigit()):
            ac = _dpkg_order(a[i]) if i < la else 0
            bc = _dpkg_order(b[j]) if j < lb else 0
            if ac != bc:
                return -1 if ac < bc else 1
            i += 1
            j += 1
        # Skip leading zeros of the digit run.
        while i < la and a[i] == "0":
            i += 1
        while j < lb and b[j] == "0":
            j += 1
        # Compare the digit runs; longer (after zero-strip) is larger, else the
        # first differing digit decides.
        first_diff = 0
        while i < la and a[i].isdigit() and j < lb and b[j].isdigit():
            if first_diff == 0:
                first_diff = ord(a[i]) - ord(b[j])
            i += 1
            j += 1
        if i < la and a[i].isdigit():
            return 1
        if j < lb and b[j].isdigit():
            return -1
        if first_diff != 0:
            return -1 if first_diff < 0 else 1
    return 0


def _split_dpkg(v: str) -> tuple[int, str, str]:
    v = v.strip()
    epoch = 0
    if ":" in v:
        head, _, rest = v.partition(":")
        if head.isdigit():
            epoch = int(head)
            v = rest
    if "-" in v:
        upstream, _, revision = v.rpartition("-")
    else:
        upstream, revision = v, ""
    return epoch, upstream, revision


def dpkg_compare(a: str, b: str) -> int:
    """Compare two Debian package versions. Returns -1 / 0 / 1."""
    ea, ua, ra = _split_dpkg(a)
    eb, ub, rb = _split_dpkg(b)
    if ea != eb:
        return -1 if ea < eb else 1
    c = _dpkg_verrevcmp(ua, ub)
    if c != 0:
        return c
    return _dpkg_verrevcmp(ra, rb)


# ---- RHEL (rpm) -----------------------------------------------------------


def _rpm_segments(s: str):
    """Yield rpmvercmp segments: runs of digits, runs of letters, and the
    special ``~`` (tilde, sorts earliest) and ``^`` (caret, sorts latest)."""
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c == "~":
            yield ("~", "~")
            i += 1
        elif c == "^":
            yield ("^", "^")
            i += 1
        elif c.isdigit():
            j = i
            while j < n and s[j].isdigit():
                j += 1
            yield ("num", s[i:j].lstrip("0") or "0")
            i = j
        elif c.isalpha():
            j = i
            while j < n and s[j].isalpha():
                j += 1
            yield ("alpha", s[i:j])
            i = j
        else:
            i += 1  # separators are not significant


def _rpm_vercmp(a: str, b: str) -> int:
    sa = list(_rpm_segments(a))
    sb = list(_rpm_segments(b))
    for (ta, va), (tb, vb) in zip(sa, sb):
        if ta == "~" or tb == "~":
            if ta != tb:
                return -1 if ta == "~" else 1
            continue
        if ta == "^" or tb == "^":
            if ta != tb:
                # caret present vs a real segment: caret is newer than nothing
                # but older than a following segment — handled by length below;
                # here both being real, caret sorts after a missing one only.
                return 1 if ta == "^" else -1
            continue
        if ta != tb:
            # a numeric segment always outranks an alphabetic one
            return 1 if ta == "num" else -1
        if ta == "num":
            if len(va) != len(vb):
                return 1 if len(va) > len(vb) else -1
            if va != vb:
                return 1 if va > vb else -1
        else:  # alpha
            if va != vb:
                return 1 if va > vb else -1
    if len(sa) == len(sb):
        return 0
    # The one with a remaining segment is newer, unless that segment is '~'.
    if len(sa) > len(sb):
        return -1 if sa[len(sb)][0] == "~" else 1
    return 1 if sb[len(sa)][0] == "~" else -1


def _split_rpm(v: str) -> tuple[int, str, str]:
    v = v.strip()
    epoch = 0
    if ":" in v:
        head, _, rest = v.partition(":")
        if head.isdigit():
            epoch = int(head)
            v = rest
    if "-" in v:
        version, _, release = v.rpartition("-")
    else:
        version, release = v, ""
    return epoch, version, release


def rpm_evr_compare(a: str, b: str) -> int:
    """Compare two RPM EVR strings ([epoch:]version[-release]). -1 / 0 / 1."""
    ea, va, ra = _split_rpm(a)
    eb, vb, rb = _split_rpm(b)
    if ea != eb:
        return -1 if ea < eb else 1
    c = _rpm_vercmp(va, vb)
    if c != 0:
        return c
    if ra and rb:
        return _rpm_vercmp(ra, rb)
    return 0
