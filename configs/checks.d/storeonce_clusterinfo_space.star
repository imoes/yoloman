DF_WARN_DEFAULT = 80.0
DF_CRIT_DEFAULT = 90.0

def _fmt_bytes(b):
    b = float(b)
    if b >= 1099511627776.0:
        return "%f TiB" % (b / 1099511627776.0)
    if b >= 1073741824.0:
        return "%f GiB" % (b / 1073741824.0)
    if b >= 1048576.0:
        return "%f MiB" % (b / 1048576.0)
    return "%f B" % b

def _try_get(d, keys):
    for k in keys:
        v = d.get(k, None)
        if v != None:
            return v
    return None

def _get_levels(params):
    levels = params.get("levels", None)
    if levels != None and len(levels) >= 2:
        return float(levels[0]), float(levels[1])
    return float(params.get("warn", DF_WARN_DEFAULT)), float(params.get("crit", DF_CRIT_DEFAULT))

def _fetch(ctx, params):
    host = params.get("host", "localhost")
    port = params.get("port", 443)
    user = params.get("username", "Admin")
    password = params.get("password", "")
    path = params.get("api_path", "/storeonceservices/cluster/")
    url = "https://%s:%d%s" % (host, port, path)
    return ctx.run([
        "curl", "-sk", "--max-time", "30",
        "-u", "%s:%s" % (user, password),
        "-H", "Accept: application/json",
        url,
    ], mutates=False)

def _parse_capacity(d):
    cap = d.get("capacitySummary", None)
    if cap == None:
        cap = {}
    cluster = d.get("cluster", None)
    if cluster == None:
        cluster = {}
    cap2 = cluster.get("capacitySummary", None)
    if cap2 == None:
        cap2 = {}

    total = _try_get(d, ["totalCapacityBytes", "totalBytes"])
    if total == None:
        total = _try_get(cap, ["totalBytes", "totalCapacityBytes"])
    if total == None:
        total = _try_get(cap2, ["totalBytes", "totalCapacityBytes"])

    free = _try_get(d, ["freeBytes", "freeSpaceBytes"])
    if free == None:
        free = _try_get(cap, ["freeSpaceBytes", "freeBytes"])
    if free == None:
        free = _try_get(cap2, ["freeSpaceBytes", "freeBytes"])

    user_data = _try_get(d, ["userDataStoredBytes"])
    if user_data == None:
        user_data = _try_get(cap, ["userDataStoredBytes"])
    if user_data == None:
        user_data = cap2.get("userDataStoredBytes", 0)
    if user_data == None:
        user_data = 0

    size_on_disk = _try_get(d, ["sizeOnDiskBytes"])
    if size_on_disk == None:
        size_on_disk = _try_get(cap, ["sizeOnDiskBytes"])
    if size_on_disk == None:
        size_on_disk = cap2.get("sizeOnDiskBytes", 0)
    if size_on_disk == None:
        size_on_disk = 0

    dedupe = _try_get(d, ["dedupeRatio"])
    if dedupe == None:
        dedupe = _try_get(cap, ["dedupeRatio"])
    if dedupe == None:
        dedupe = cap2.get("dedupeRatio", 0.0)
    if dedupe == None:
        dedupe = 0.0

    return total, free, user_data, size_on_disk, dedupe

def main(ctx, params):
    if params.get("_discover"):
        res = _fetch(ctx, params)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        stdout = res.stdout.strip()
        if not (stdout.startswith("{") or stdout.startswith("[")):
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        d = json.decode(stdout)
        total, _free, _u, _s, _r = _parse_capacity(d)
        if total == None:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered 1 items",
            "data": {"discovery": [{
                "item": "Total Capacity",
                "params": {"levels": [DF_WARN_DEFAULT, DF_CRIT_DEFAULT]},
                "metrics": ["total_bytes", "free_bytes", "used_bytes", "used_percent",
                            "user_data_stored_bytes", "size_on_disk_bytes", "dedupe_ratio"],
            }]},
        }

    res = _fetch(ctx, params)
    if res.rc != 0:
        return {"changed": False,
                "msg": "StoreOnce API unreachable: " + res.stderr.strip(),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    stdout = res.stdout.strip()
    if not stdout or not (stdout.startswith("{") or stdout.startswith("[")):
        return {"changed": False,
                "msg": "Non-JSON response from StoreOnce API",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    d = json.decode(stdout)
    total, free, user_data, size_on_disk, dedupe = _parse_capacity(d)

    if total == None or free == None:
        return {"changed": False,
                "msg": "Capacity data missing in API response",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    total = float(total)
    free = float(free)
    user_data = float(user_data)
    size_on_disk = float(size_on_disk)
    dedupe = float(dedupe)

    used = total - free
    used_pct = (used / total * 100.0) if total > 0.0 else 0.0

    warn, crit = _get_levels(params)
    state = "CRIT" if (used_pct >= crit) else ("WARN" if (used_pct >= warn) else "OK")

    thresh = ""
    if state == "WARN":
        thresh = " (warn >= %f%%)" % warn
    elif state == "CRIT":
        thresh = " (crit >= %f%%)" % crit

    msg = "Total: %s, Used: %s (%f%%%s), Free: %s" % (
        _fmt_bytes(total), _fmt_bytes(used), used_pct, thresh, _fmt_bytes(free))
    details = "User Data Stored: %s, Size on Disk: %s, Dedupe Ratio: %f:1" % (
        _fmt_bytes(user_data), _fmt_bytes(size_on_disk), dedupe)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "total_bytes": total,
                "free_bytes": free,
                "used_bytes": used,
                "used_percent": used_pct,
                "user_data_stored_bytes": user_data,
                "size_on_disk_bytes": size_on_disk,
                "dedupe_ratio": dedupe,
            },
            "details": details,
        },
    }