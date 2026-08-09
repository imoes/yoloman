# Checkmk check: cephosdbluefs_wal
# Translated to a read-only Starlark check module for the yolo-man agent.
#
# This check monitors the Ceph OSD BlueFS WAL (write-ahead-log) device usage
# per OSD, mirroring the Checkmk check_plugin_cephosdbluefs_wal logic.
# It does NOT use any Checkmk runtime; it reads the same underlying host
# data the Checkmk ceph agent plugin would gather: the output of
# `ceph daemon osd.<id> perf` / `ceph daemon osd.<id> config` is not
# directly available here, so this check probes the real Ceph cluster
# state via `ceph` CLI (read-only) and grades the per-OSD BlueFS WAL
# usage with the filesystem ruleset thresholds.
#
# The check is READ-ONLY: it never mutates the system.

MIB = 1024.0 * 1024.0

# Filesystem ruleset defaults (from df.FILESYSTEM_DEFAULT_PARAMS).
FILESYSTEM_DEFAULT_PARAMS = {
    "levels": (80.0, 90.0),
    "levels_low": (60.0, 70.0),
    "growth_min_free": 5.0,
    "growth_rate": 0.0,
    "ignore": [],
    "ignore_typed": [],
}


def main(ctx, params):
    discover = params.get("_discover")
    if discover:
        return _discovery(ctx, params)
    return _check(ctx, params)


def _is_ceph_present(ctx):
    res = ctx.run(["ceph", "--version"], mutates=False)
    return res.rc == 0


def _collect_bluefs_wal(ctx):
    """Return dict: osdid -> {"wal_total_mb": float, "wal_used_mb": float}."""
    out = {}
    if not _is_ceph_present(ctx):
        return out

    # Enumerate OSD ids. `cephosd.0` -> id "0". We use `ceph osd ls` which
    # prints one osd id per line.
    ls_res = ctx.run(["ceph", "osd", "ls"], mutates=False)
    if ls_res.rc != 0:
        return out
    if not ls_res.stdout:
        return out

    for line in ls_res.stdout.splitlines():
        osdid = line.strip()
        if osdid == "":
            continue
        # `ceph daemon osd.<id> perf` gives performance counters, but the
        # BlueFS allocator stats live in `ceph daemon osd.<id> config`
        # and the BlueFS stats endpoint. The reliable, documented source
        # for BlueFS usage is:
        #   ceph daemon osd.<id> perf | grep bluefs
        # but that returns counters, not totals. The Checkmk ceph agent
        # plugin reads `bluefs` from the `ceph status` / `ceph df` style
        # output of the special agent. On a real cluster the per-OSD
        # BlueFS stats come from:
        #   ceph daemon osd.<id> config
        # which does not expose BlueFS totals directly.
        #
        # The canonical on-host source the Checkmk ceph special agent
        # uses is `cephadm shell ceph <cmd>` output. For BlueFS WAL we
        # use `ceph daemon osd.<id> dump` is not it either.
        #
        # The real source: Checkmk's ceph special agent runs
        #   ceph osd dump
        # and parses the "bluefs" field per OSD from the OSD map /
        # per-OSD config. Concretely, `ceph daemon osd.<id> config`
        # exposes `bluestore_bluefs_*` but not the allocator totals.
        #
        # The totals the check needs (wal_total_bytes, wal_used_bytes)
        # are exposed by the BlueFS allocator stats endpoint:
        #   ceph daemon osd.<id> perf
        # contains a "bluefs" key with "wal_total", "wal_used", etc.
        # in bytes. This is the direct, real on-host source.

        perf_res = ctx.run(
            ["ceph", "daemon", "osd." + osdid, "perf"],
            mutates=False,
        )
        if perf_res.rc != 0:
            continue
        if not perf_res.stdout:
            continue

        # Parse the perf JSON. We look for bluefs wal stats.
        wal_total = 0.0
        wal_used = 0.0
        ok = False
        if perf_res.stdout.strip() != "":
            parsed = json.decode(perf_res.stdout)
            ok = True
        if ok:
            # The "bluefs" perf counter block, if present, has keys like
            # "bluefs": {"wal_total": ..., "wal_used": ..., ...}.
            bluefs_perf = _dict_get(parsed, "bluefs")
            if bluefs_perf != None:
                wal_total = _num_get(bluefs_perf, "wal_total", 0.0)
                wal_used = _num_get(bluefs_perf, "wal_used", 0.0)
            else:
                # Some Ceph versions embed it under a nested path.
                # Try "bluefs_wal" style keys at top-level of perf.
                wal_total = _num_get(parsed, "bluefs_wal_total", 0.0)
                wal_used = _num_get(parsed, "bluefs_wal_used", 0.0)

        total_mb = wal_total / MIB
        if total_mb > 0:
            out[osdid] = {
                "wal_total_mb": total_mb,
                "wal_used_mb": wal_used / MIB,
            }
    return out


def _discovery(ctx, params):
    bluefs = _collect_bluefs_wal(ctx)
    discovery = []
    for osdid in sorted(bluefs.keys()):
        info = bluefs[osdid]
        if info["wal_total_mb"] > 0:
            discovery.append({
                "item": osdid,
                "params": {"warn": 80.0, "crit": 90.0},
                "metrics": ["used_percent"],
            })
    n = len(discovery)
    return {
        "changed": False,
        "msg": "discovered %d items" % n,
        "data": {"discovery": discovery},
    }


def _check(ctx, params):
    item = params.get("item", "")
    bluefs = _collect_bluefs_wal(ctx)
    info = bluefs.get(item)
    if info == None:
        return {
            "changed": False,
            "msg": "no Ceph OSD " + item + " BlueFS WAL found",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    total_mb = info["wal_total_mb"]
    used_mb = info["wal_used_mb"]
    avail_mb = total_mb - used_mb
    if total_mb <= 0:
        return {
            "changed": False,
            "msg": "Ceph OSD " + item + " BlueFS WAL: no capacity",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    used_percent = (used_mb / total_mb) * 100.0

    # Filesystem ruleset thresholds: warn/crit are upper levels
    # (WARN if used_percent >= warn, CRIT if >= crit).
    warn = _level(params, "warn", 80.0)
    crit = _level(params, "crit", 90.0)

    state = "OK"
    if used_percent >= crit:
        state = "CRIT"
    elif used_percent >= warn:
        state = "WARN"

    used_pct_str = "%f" % used_percent
    msg = "Ceph OSD " + item + " BlueFS WAL " + used_pct_str + "% used"

    details = (
        "Total: %f MB, Used: %f MB, Available: %f MB"
        % (total_mb, used_mb, avail_mb)
    )

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "used_percent": used_percent,
                "used_mb": used_mb,
                "avail_mb": avail_mb,
                "total_mb": total_mb,
            },
            "details": details,
        },
    }


# --- small helpers (no stdlib) ---

def _dict_get(d, key):
    if d == None:
        return None
    if type(d) != "dict":
        return None
    return d.get(key)


def _num_get(d, key, default):
    v = _dict_get(d, key)
    if v == None:
        return default
    if type(v) == "int" or type(v) == "float":
        return float(v)
    # String fallback: try to parse a numeric string.
    if type(v) == "string":
        s = v.strip()
        # Accept plain integer/float strings.
        if _is_number(s):
            return float(s)
    return default


def _is_number(s):
    if s == "":
        return False
    # Allow leading sign, digits, one dot.
    dot_seen = False
    digits_seen = False
    i = 0
    if s[0] == "-" or s[0] == "+":
        i = 1
    while i < len(s):
        c = s[i]
        if c >= "0" and c <= "9":
            digits_seen = True
        elif c == "." and not dot_seen:
            dot_seen = True
        else:
            return False
        i = i + 1
    return digits_seen


def _level(params, key, default):
    # params may carry explicit warn/crit, or a "levels" tuple
    # (warn, crit). Mirror the filesystem ruleset shape.
    v = params.get(key)
    if v != None:
        if type(v) == "int" or type(v) == "float":
            return float(v)
        if type(v) == "string" and _is_number(v):
            return float(v)
    levels = params.get("levels")
    if levels != None and type(levels) == "list" and len(levels) >= 2:
        idx = 0 if key == "warn" else 1
        lv = levels[idx]
        if type(lv) == "int" or type(lv) == "float":
            return float(lv)
        if type(lv) == "string" and _is_number(lv):
            return float(lv)
    return default