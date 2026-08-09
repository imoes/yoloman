# Checkmk check: cephosdbluefs_db / cephosdbluefs_wal / cephosdbluefs_slow
# Translated to a read-only Starlark check module for the yolo-man agent.
# Data source: `ceph df` command output (JSON). No Checkmk installed on host.

MIB = 1024.0 * 1024.0


def _ceph_df_json(ctx):
    res = ctx.run(["ceph", "df", "detail", "--format", "json"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return None
    return json.decode(res.stdout)


def _bluefs_from_detail(d):
    """Extract a BlueFS-like dict from ceph df detail for a given osd."""
    # ceph df detail JSON: {"filesystems": [...], "pools": [...], "osds": [...]}
    osds = d.get("osds", []) if d else []
    out = {}
    for o in osds:
        name = o.get("name", "")
        # name like "osd.0" -> use osdid "0"
        if name.startswith("osd."):
            osdid = name[len("osd."):]
        else:
            osdid = name
        bluefs = o.get("bluefs")
        if bluefs == None:
            continue
        out[osdid] = {
            "db_total_bytes": float(bluefs.get("db_total_bytes", 0)),
            "db_used_bytes": float(bluefs.get("db_used_bytes", 0)),
            "wal_total_bytes": float(bluefs.get("wal_total_bytes", 0)),
            "wal_used_bytes": float(bluefs.get("wal_used_bytes", 0)),
            "slow_total_bytes": float(bluefs.get("slow_total_bytes", 0)),
            "slow_used_bytes": float(bluefs.get("slow_used_bytes", 0)),
        }
    return out


def _to_bluefs_mb(b):
    return {
        "db_total_mb": b["db_total_bytes"] / MIB,
        "db_used_mb": b["db_used_bytes"] / MIB,
        "wal_total_mb": b["wal_total_bytes"] / MIB,
        "wal_used_mb": b["wal_used_bytes"] / MIB,
        "slow_total_mb": b["slow_total_bytes"] / MIB,
        "slow_used_mb": b["slow_used_bytes"] / MIB,
        "db_avail_mb": (b["db_total_bytes"] - b["db_used_bytes"]) / MIB,
        "wal_avail_mb": (b["wal_total_bytes"] - b["wal_used_bytes"]) / MIB,
        "slow_avail_mb": (b["slow_total_bytes"] - b["slow_used_bytes"]) / MIB,
    }


def _df_grade(total, avail, warn, crit):
    """Reproduce logic of df.df_check_filesystem_single for used-percent."""
    if total <= 0:
        return "UNKNOWN", 0.0, ""
    used = total - avail
    pct = (used / total) * 100.0 if total > 0 else 0.0
    if crit != None and pct >= crit:
        return "CRIT", pct, "usage %d%% reached critical level %d%%" % (pct, crit)
    if warn != None and pct >= warn:
        return "WARN", pct, "usage %d%% reached warning level %d%%" % (pct, warn)
    return "OK", pct, "Ceph OSD BlueFS: usage %d%%" % pct


def main(ctx, params):
    mode = params.get("_checkmk_mode", "db")
    item = params.get("item", "")

    # Probe that ceph exists
    probe = ctx.run(["ceph", "--version"], mutates=False)
    if probe.rc != 0:
        empty = {"changed": False, "data": {"discovery": []}}
        if params.get("_discover"):
            return empty
        return {
            "changed": False,
            "msg": "ceph not found / not installed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "ceph binary not available"},
        }

    d = _ceph_df_json(ctx)

    if params.get("_discover"):
        if d == None:
            return {"changed": False, "msg": "no ceph df data", "data": {"discovery": []}}
        raw = _bluefs_from_detail(d)
        out = []
        for osdid, b in raw.items():
            bf = _to_bluefs_mb(b)
            total_key = mode + "_total_mb"
            if bf.get(total_key, 0) > 0:
                out.append({"item": osdid, "params": {}, "metrics": ["used_percent"]})
        return {
            "changed": False,
            "msg": "discovered %d items" % len(out),
            "data": {"discovery": out},
        }

    # Check mode
    if d == None:
        return {
            "changed": False,
            "msg": "no ceph df data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    raw = _bluefs_from_detail(d)
    if item == "" or not raw:
        if item == "":
            # try first
            keys = sorted(raw.keys())
            if len(keys) == 0:
                return {
                    "changed": False,
                    "msg": "no osd with bluefs",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
                }
            item = keys[0]
    b = raw.get(item)
    if b == None:
        return {
            "changed": False,
            "msg": "no such osd: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    bf = _to_bluefs_mb(b)
    total_key = mode + "_total_mb"
    avail_key = mode + "_avail_mb"
    total = bf.get(total_key, 0)
    avail = bf.get(avail_key, 0)

    warn = params.get("warn", 80)
    crit = params.get("crit", 90)

    state, pct, detail = _df_grade(total, avail, warn, crit)
    return {
        "changed": False,
        "msg": "OSD %s %s: %d%% used" % (item, mode, pct),
        "data": {"state": state, "metrics": {"used_percent": pct}, "details": detail},
    }