def _fetch_column(ctx, host, community, oid, index):
    full = oid + "." + index
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, full], mutates=False)
    if res.rc != 0 or not res.stdout:
        return None
    return res.stdout.strip()

def main(ctx, params):
    if params.get("_discover"):
        # Probe for the real thing first: detect Isilon via sysDescr
        descr = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                         "-Oqv", "-Ov", params.get("host", "localhost"), ".1.3.6.1.2.1.1.1.0"],
                        mutates=False)
        if descr.rc != 0 or "isilon" not in (descr.stdout or "").lower():
            return {"changed": False, "msg": "no Isilon device found", "data": {"discovery": []}}
        # Walk the quotaPath column to discover items
        base = ".1.3.6.1.4.1.12124.1.12.1.1"
        walk = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                        "-Oqn", params.get("host", "localhost"), base + ".5"], mutates=False)
        if walk.rc != 0:
            return {"changed": False, "msg": "no Isilon quota data found",
                    "data": {"discovery": []}}
        items = []
        for line in walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            index = parts[0][len(base + ".5") + 1:]
            path_val = parts[1].strip()
            # strip quotes if present
            if path_val.startswith('"') and path_val.endswith('"'):
                path_val = path_val[1:-1]
            items.append(path_val)
        discovery = []
        for path_val in items:
            discovery.append({"item": path_val, "params": {}, "metrics": ["used_percent"]})
        return {"changed": False, "msg": "discovered %d quota paths" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.12124.1.12.1.1"

    # First, find the index for the requested item by walking the quotaPath column
    walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".5"],
                   mutates=False)
    if walk.rc != 0:
        return {"changed": False, "msg": "no Isilon quota data found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    target_index = None
    for line in walk.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid_full = parts[0]
        val = parts[1].strip()
        if val.startswith('"') and val.endswith('"'):
            val = val[1:-1]
        index = oid_full[len(base + ".5") + 1:]
        if val == item:
            target_index = index
            break

    if target_index == None:
        return {"changed": False, "msg": "no such quota path: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Fetch all columns by index
    hard_threshold = _fetch_column(ctx, host, community, base + ".7", target_index)
    soft_defined = _fetch_column(ctx, host, community, base + ".8", target_index)
    soft_threshold = _fetch_column(ctx, host, community, base + ".9", target_index)
    adv_defined = _fetch_column(ctx, host, community, base + ".10", target_index)
    adv_threshold = _fetch_column(ctx, host, community, base + ".11", target_index)
    usage = _fetch_column(ctx, host, community, base + ".13", target_index)

    if hard_threshold == None or usage == None:
        return {"changed": False, "msg": "failed to fetch quota data for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    hard_threshold = int(hard_threshold)
    soft_threshold = int(soft_threshold or "0")
    adv_threshold = int(adv_threshold or "0")
    usage = int(usage)

    # Note 2: use the "hardest" threshold that isn't 0 for the disk limit
    assumed_size = hard_threshold if hard_threshold else (soft_threshold if soft_threshold else adv_threshold)
    if assumed_size == 0:
        return {"changed": False, "msg": "no quota threshold defined for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # If levels not configured, derive from soft/advisory threshold
    warn = None
    crit = None
    if "levels" in params:
        levels = params["levels"]
        if type(levels) == "list":
            warn = float(levels[0]) if len(levels) > 0 else None
            crit = float(levels[1]) if len(levels) > 1 else None
    if warn == None and crit == None:
        if soft_defined == "1" or adv_defined == "1":
            if adv_threshold != 0:
                warn = adv_threshold * 100.0 / assumed_size
            else:
                warn = 80.0
            if soft_threshold != 0:
                crit = soft_threshold * 100.0 / assumed_size
            else:
                crit = 90.0

    if warn == None:
        warn = 80.0
    if crit == None:
        crit = 90.0

    used = usage
    used_mb = used / (1024.0 * 1024.0)
    total_mb = assumed_size / (1024.0 * 1024.0)
    percent = used * 100.0 / assumed_size if assumed_size != 0 else 0

    # df_check_filesystem_list grades: WARN if percent >= warn, CRIT if percent >= crit
    if percent >= crit:
        state = "CRIT"
    elif percent >= warn:
        state = "WARN"
    else:
        state = "OK"

    avail_mb = (assumed_size - used) / (1024.0 * 1024.0)
    msg = "%s: %s" % (item, "%f MB used, %f MB available, %f%% of %s MB" %
                      (used_mb, avail_mb, percent, total_mb))
    details = "<table border=1><tr><th>Path</th><th>Total MB</th><th>Used MB</th><th>Avail MB</th><th>Use%</th></tr>"
    details = details + "<tr><td>%s</td><td>%f</td><td>%f</td><td>%f</td><td>%f</td></tr></table>" % (
        item, total_mb, used_mb, avail_mb, percent)

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"used_percent": percent}, "details": details}}