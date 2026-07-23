# Health level → state: 1=OK, 2=Warning, 3+=Critical (matches storeonce lib STATE_MAP)
HEALTH_LEVEL_MAP = {"1": "OK", "2": "WARN", "3": "CRIT", "4": "CRIT"}
STATE_ORDER = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}

def _worst_state(a, b):
    if STATE_ORDER.get(a, 3) >= STATE_ORDER.get(b, 3):
        return a
    return b

def _health_state(level):
    return HEALTH_LEVEL_MAP.get(str(level), "UNKNOWN")

def _format_uptime(seconds):
    secs = int(float(str(seconds)))
    days = secs // 86400
    hours = (secs % 86400) // 3600
    mins = (secs % 3600) // 60
    parts = []
    if days > 0:
        parts.append("%d days" % days)
    if hours > 0:
        parts.append("%d hours" % hours)
    parts.append("%d minutes" % mins)
    return " ".join(parts)

def _to_float(v):
    if v == None:
        return 0.0
    return float(str(v))

def _get(data, *keys):
    for k in keys:
        v = data.get(k)
        if v != None:
            return v
    return None

def _query_api(ctx, params):
    host = params.get("host", "localhost")
    port = params.get("port", 443)
    username = params.get("username", "Admin")
    password = params.get("password", "")
    path = params.get("api_path", "/storeonceservices/cluster/")
    url = "https://%s:%s%s" % (host, str(int(port)), path)
    res = ctx.run([
        "curl", "-s", "-k", "--max-time", "30",
        "-u", "%s:%s" % (username, password),
        "-H", "Accept: application/json",
        url,
    ], mutates=False)
    if res.rc != 0:
        return None
    stdout = res.stdout.strip()
    if not stdout:
        return None
    return json.decode(stdout)

def main(ctx, params):
    if params.get("_discover"):
        data = _query_api(ctx, params)
        if data == None:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}

        # API may nest fields under "clusterInfo" or return them at top level
        info = data.get("clusterInfo", data)
        product_class = _get(info, "productClass", "Product Class") or ""

        items = []
        if product_class:
            items.append({
                "item": product_class,
                "params": {},
                "metrics": [],
            })
        if _get(info, "clusterHealth", "Cluster Health") != None:
            items.append({
                "item": "Appliance Status",
                "params": {},
                "metrics": [],
            })
        items.append({
            "item": "Total Capacity",
            "params": {"warn": 80.0, "crit": 90.0},
            "metrics": ["total_bytes", "free_bytes", "used_percent", "dedupe_ratio"],
        })
        items.append({
            "item": "Uptime",
            "params": {},
            "metrics": ["uptime"],
        })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    data = _query_api(ctx, params)
    if data == None:
        return {
            "changed": False,
            "msg": "cannot connect to StoreOnce API",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    info = data.get("clusterInfo", data)

    if item == "Uptime":
        uptime_raw = _get(info, "uptimeSeconds", "Uptime Seconds")
        if uptime_raw == None:
            return {
                "changed": False,
                "msg": "uptime data not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        uptime_secs = _to_float(uptime_raw)
        min_warn = params.get("min_warn")
        min_crit = params.get("min_crit")
        state = "OK"
        if min_crit != None and uptime_secs < _to_float(min_crit):
            state = "CRIT"
        elif min_warn != None and uptime_secs < _to_float(min_warn):
            state = "WARN"
        return {
            "changed": False,
            "msg": "Up for: %s" % _format_uptime(uptime_secs),
            "data": {
                "state": state,
                "metrics": {"uptime": uptime_secs},
                "details": "",
            },
        }

    if item == "Total Capacity":
        total_raw = _get(info, "totalCapacityBytes", "Total Capacity (bytes)")
        free_raw = _get(info, "freeSpaceBytes", "Free Space (bytes)")
        dedupe_raw = _get(info, "dedupeRatio", "Dedupe Ratio")
        if total_raw == None or free_raw == None:
            return {
                "changed": False,
                "msg": "capacity data not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        total = _to_float(total_raw)
        free = _to_float(free_raw)
        used = total - free
        warn_pct = _to_float(params.get("warn", 80.0))
        crit_pct = _to_float(params.get("crit", 90.0))
        used_pct = (used / total * 100.0) if total > 0.0 else 0.0
        state = "CRIT" if used_pct >= crit_pct else ("WARN" if used_pct >= warn_pct else "OK")
        # StoreOnce reports in SI (bytes / 1e9 = GB, matching section "Total Capacity" field)
        total_gb = total / 1000000000.0
        free_gb = free / 1000000000.0
        dedupe = _to_float(dedupe_raw)
        return {
            "changed": False,
            "msg": "Total: %f GB, Free: %f GB, Used: %f%%, Dedupe: %fx" % (
                total_gb, free_gb, used_pct, dedupe
            ),
            "data": {
                "state": state,
                "metrics": {
                    "total_bytes": total,
                    "free_bytes": free,
                    "used_percent": used_pct,
                    "dedupe_ratio": dedupe,
                },
                "details": "",
            },
        }

    if item == "Appliance Status":
        cluster_status = _get(info, "clusterStatus", "Cluster Status") or "Unknown"
        repl_status = _get(info, "replicationStatus", "Replication Status") or "Unknown"
        cluster_health = _get(info, "clusterHealth", "Cluster Health") or "Unknown"
        cluster_lvl = _get(info, "clusterHealthLevel", "Cluster Health Level")
        repl_health = _get(info, "replicationHealth", "Replication Health") or "Unknown"
        repl_lvl = _get(info, "replicationHealthLevel", "Replication Health Level")
        cs = _health_state(cluster_lvl) if cluster_lvl != None else "UNKNOWN"
        rs = _health_state(repl_lvl) if repl_lvl != None else "UNKNOWN"
        worst = _worst_state(cs, rs)
        return {
            "changed": False,
            "msg": "Cluster Status: %s, Replication Status: %s" % (cluster_status, repl_status),
            "data": {
                "state": worst,
                "metrics": {},
                "details": "Cluster Health: %s, Replication Health: %s" % (cluster_health, repl_health),
            },
        }

    # General info — item equals the discovered product class
    appliance_name = _get(info, "applianceName", "applicationName", "hostname", "Appliance Name") or "unknown"
    serial = _get(info, "serialNumber", "Serial Number") or "unknown"
    version = _get(info, "softwareVersion", "Software Version") or "unknown"
    return {
        "changed": False,
        "msg": "Name: %s, Serial Number: %s, Version: %s" % (appliance_name, serial, version),
        "data": {
            "state": "OK",
            "metrics": {},
            "details": "",
        },
    }