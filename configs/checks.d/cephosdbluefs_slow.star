# ===== constants (top level, required by Starlark) =====
MIB = 1024.0 * 1024.0

# ===== helper functions =====
def _parse_bluefs(json_str):
    if not json_str or json_str.strip() == "":
        return {}
    # Guard before json.decode: only proceed if we have non-empty input
    # json.decode will fail() internally on invalid JSON, but that's acceptable
    # because the agent output should always be well-formed if present
    if not json_str or len(json_str.strip()) == 0:
        return {}
    data = json.decode(json_str)
    if type(data) != "dict":
        return {}
    result = {}
    for osdid, raw_inner in data.items():
        if type(raw_inner) != "dict":
            continue
        bluefs = raw_inner.get("bluefs")
        if bluefs == None or type(bluefs) != "dict":
            continue
        db_total_mb = float(bluefs.get("db_total_bytes", "0")) / MIB
        db_used_mb = float(bluefs.get("db_used_bytes", "0")) / MIB
        wal_total_mb = float(bluefs.get("wal_total_bytes", "0")) / MIB
        wal_used_mb = float(bluefs.get("wal_used_bytes", "0")) / MIB
        slow_total_mb = float(bluefs.get("slow_total_bytes", "0")) / MIB
        slow_used_mb = float(bluefs.get("slow_used_bytes", "0")) / MIB
        result[osdid] = {
            "db_total_mb": db_total_mb,
            "db_used_mb": db_used_mb,
            "db_avail_mb": db_total_mb - db_used_mb,
            "wal_total_mb": wal_total_mb,
            "wal_used_mb": wal_used_mb,
            "wal_avail_mb": wal_total_mb - wal_used_mb,
            "slow_total_mb": slow_total_mb,
            "slow_used_mb": slow_used_mb,
            "slow_avail_mb": slow_total_mb - slow_used_mb,
        }
    return result

def _check_filesystem_single(value_store, item, total_mb, avail_mb, *unused_args, **params):
    # Reproduce df.df_check_filesystem_single behavior for the critical params:
    # - levels_upper: warn, crit thresholds for used_percent
    # - levels_lower: warn, crit thresholds for avail_percent (if present)
    # We implement the core logic: determine used_percent, compare to warn/crit

    used_mb = total_mb - avail_mb
    if total_mb <= 0:
        return {"state": "UNKNOWN", "msg": "total size is zero", "metrics": {}}
    used_percent = (used_mb / total_mb) * 100.0
    avail_percent = 100.0 - used_percent

    warn = params.get("warn", None)
    crit = params.get("crit", None)
    # Checkmk default FILESYSTEM_DEFAULT_PARAMS uses levels_upper for warn/crit as percentages
    # If warn/crit are None or not set, default thresholds are 80/90 (from Checkmk standard)
    if warn == None:
        warn = 80.0
    if crit == None:
        crit = 90.0

    # Determine state based on used_percent (upper thresholds)
    if used_percent >= crit:
        state = "CRIT"
    elif used_percent >= warn:
        state = "WARN"
    else:
        state = "OK"

    # Format message like Checkmk: "Used: X.XX% (Y.YY MB of Z.ZZ MB), ...", but keep it simple
    msg = "Size: %f MB, Used: %f%%" % (total_mb, used_percent)

    # Build metrics: match df-style names
    metrics = {
        "used": used_mb,
        "avail": avail_mb,
        "size": total_mb,
        "used_percent": used_percent,
        "avail_percent": avail_percent,
    }

    return {"state": state, "msg": msg, "metrics": metrics}

def main(ctx, params):
    if params.get("_discover"):
        # Fetch the ceph osd bluefs data via agent section: read the raw JSON file
        # Agent section name is 'cephosdbluefs'; on-host it comes from agent output
        # The Checkmk agent section is populated by the ceph command:
        #   ceph --admin-daemon /run/ceph/$pid.asok bluefs info
        # We'll use the standard way to get bluefs info: run the command as root
        # Since we can't assume ceph is installed or accessible, fallback to agent file if present
        # The Checkmk agent plugin fetches bluefs info via ceph socket; we replicate that.
        # For compatibility, we try the ceph command; if it fails, return empty (no items).
        res = ctx.run(["ceph", "--admin-daemon", "/run/ceph/ceph-osd.*.asok", "bluefs", "info"], mutates=False)
        if res.rc != 0:
            # Fallback: if ceph fails, assume no OSDs present -> return empty discovery
            return {"changed": False, "msg": "discovered 0 OSDs", "data": {"discovery": []}}
        # Guard before json.decode: only proceed if we have non-empty stdout
        if not res.stdout or len(res.stdout.strip()) == 0:
            return {"changed": False, "msg": "discovered 0 OSDs", "data": {"discovery": []}}
        data = json.decode(res.stdout)
        if type(data) != "dict":
            return {"changed": False, "msg": "discovered 0 OSDs", "data": {"discovery": []}}
        out = []
        for osdid, raw_inner in data.items():
            if type(raw_inner) != "dict":
                continue
            bluefs = raw_inner.get("bluefs")
            if bluefs == None or type(bluefs) != "dict":
                continue
            slow_total_mb = float(bluefs.get("slow_total_bytes", "0")) / MIB
            if slow_total_mb <= 0:
                continue
            # Suggest thresholds using Checkmk defaults (FILESYSTEM_DEFAULT_PARAMS)
            out.append({
                "item": osdid,
                "params": {"warn": 80.0, "crit": 90.0},  # default levels_upper
                "metrics": ["used_percent", "used", "avail", "size", "avail_percent"]
            })
        return {"changed": False, "msg": "discovered %d OSDs" % len(out), "data": {"discovery": out}}

    # Check mode
    item = params.get("item", "")
    res = ctx.run(["ceph", "--admin-daemon", "/run/ceph/ceph-osd.%s.asok" % item, "bluefs", "info"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "osd %s not found or bluefs data unavailable" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    # Guard before json.decode: only proceed if we have non-empty stdout
    if not res.stdout or len(res.stdout.strip()) == 0:
        return {"changed": False, "msg": "osd %s not found or bluefs data unavailable" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = json.decode(res.stdout)
    if type(data) != "dict":
        return {"changed": False, "msg": "osd %s not found or bluefs data unavailable" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    raw_inner = data.get(item)
    if type(raw_inner) != "dict":
        return {"changed": False, "msg": "osd %s not found or bluefs data unavailable" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    bluefs = raw_inner.get("bluefs")
    if bluefs == None or type(bluefs) != "dict":
        return {"changed": False, "msg": "osd %s not found or bluefs data unavailable" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    slow_total_mb = float(bluefs.get("slow_total_bytes", "0")) / MIB
    slow_used_mb = float(bluefs.get("slow_used_bytes", "0")) / MIB
    slow_avail_mb = slow_total_mb - slow_used_mb

    if slow_total_mb <= 0:
        return {"changed": False, "msg": "osd %s: slow device size is zero" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Use the same df.df_check_filesystem_single logic as the original
    result = _check_filesystem_single(
        {},  # value_store (not used in Starlark here since we don't store historical data)
        item,
        slow_total_mb,
        slow_avail_mb,
        0,  # *unused_args
        **params
    )

    state = result["state"]
    msg = "Ceph OSD %s Slow: %s" % (item, result["msg"])
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": result["metrics"], "details": ""}}
