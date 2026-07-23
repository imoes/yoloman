def main(ctx, params):
    host = params.get("host", "localhost")
    port = params.get("port", 443)
    username = params.get("username", "admin")
    password = params.get("password", "")

    gateway = "https://%s:%d" % (host, port)

    # Authenticate with ScaleIO gateway — returns a quoted token string
    login_res = ctx.run([
        "curl", "-sk", "-X", "GET",
        "-u", "%s:%s" % (username, password),
        gateway + "/api/login",
    ], mutates=False)

    if login_res.rc != 0 or not login_res.stdout.strip():
        err = "ScaleIO login failed"
        if params.get("_discover"):
            return {"changed": False, "msg": err, "data": {"discovery": []}}
        return {"changed": False, "msg": err,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    token = login_res.stdout.strip().strip('"')

    # Fetch all System instances
    sys_res = ctx.run([
        "curl", "-sk",
        "-u", "%s:" % token,
        "-H", "Accept: application/json",
        gateway + "/api/types/System/instances",
    ], mutates=False)

    if sys_res.rc != 0 or not sys_res.stdout.strip():
        err = "failed to query ScaleIO systems"
        if params.get("_discover"):
            return {"changed": False, "msg": err, "data": {"discovery": []}}
        return {"changed": False, "msg": err,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    systems = json.decode(sys_res.stdout.strip())
    if type(systems) != "list":
        systems = [systems]

    # DISCOVERY MODE
    if params.get("_discover"):
        disc = []
        for sysobj in systems:
            sys_id = sysobj.get("id", "")
            if not sys_id:
                continue
            high = float(sysobj.get("capacityAlertHighThreshold", 80))
            crit_lvl = float(sysobj.get("capacityAlertCriticalThreshold", 90))
            disc.append({
                "item": sys_id,
                "params": {"warn": high, "crit": crit_lvl},
                "metrics": ["used_mb", "free_mb", "total_mb", "used_percent"],
            })
        return {"changed": False, "msg": "discovered %d ScaleIO systems" % len(disc),
                "data": {"discovery": disc}}

    # CHECK MODE
    item = params.get("item", "")
    target = None
    for sysobj in systems:
        if sysobj.get("id", "") == item:
            target = sysobj
            break

    if target == None:
        return {"changed": False, "msg": "system not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Fetch statistics for actual capacity usage (maxCapacityInKb, unusedCapacityInKb)
    stats_res = ctx.run([
        "curl", "-sk",
        "-u", "%s:" % token,
        gateway + "/api/instances/System::%s/relationships/Statistics" % item,
    ], mutates=False)

    if stats_res.rc != 0 or not stats_res.stdout.strip():
        return {"changed": False, "msg": "failed to get statistics for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    stats = json.decode(stats_res.stdout.strip())
    if type(stats) == "list":
        if len(stats) == 0:
            return {"changed": False, "msg": "empty statistics for " + item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        stats = stats[0]

    total_kb = float(stats.get("maxCapacityInKb", 0))
    free_kb = float(stats.get("unusedCapacityInKb", 0))

    if total_kb == 0.0:
        return {"changed": False, "msg": "zero total capacity for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Convert KB → MB for threshold arithmetic (matches df_check_filesystem_single units)
    total_mb = total_kb / 1024.0
    free_mb = free_kb / 1024.0
    used_mb = total_mb - free_mb
    used_pct = used_mb / total_mb * 100.0

    # Thresholds: system's own alert levels as default, overridable via params
    sys_warn = float(target.get("capacityAlertHighThreshold", 80))
    sys_crit = float(target.get("capacityAlertCriticalThreshold", 90))
    warn = float(params.get("warn", sys_warn))
    crit_thr = float(params.get("crit", sys_crit))

    state = "OK"
    if used_pct >= crit_thr:
        state = "CRIT"
    elif used_pct >= warn:
        state = "WARN"

    # Display in TB (1 TB = 1048576 MB)
    total_tb = total_mb / 1048576.0
    used_tb = used_mb / 1048576.0
    free_tb = free_mb / 1048576.0

    msg = "Used: %f TB of %f TB (%f%%), Free: %f TB" % (
        used_tb, total_tb, used_pct, free_tb,
    )

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "used_mb": used_mb,
                "free_mb": free_mb,
                "total_mb": total_mb,
                "used_percent": used_pct,
            },
            "details": "warn=%f%% crit=%f%%" % (warn, crit_thr),
        },
    }