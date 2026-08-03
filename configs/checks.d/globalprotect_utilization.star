# Parameters the check accepts (your params dict; use the Checkmk defaults):
#   host: target PanOS host (default localhost)
#   community: SNMP community (default public)
#   utilization: levels dict, e.g. {"levels": (warn, crit)}
#   active_tunnels: levels dict, e.g. {"levels": (warn, crit)}

def _snmp_walk_indexed(ctx, community, host, oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout:
        return None
    out = []
    for line in res.stdout.split("\n"):
        line = line.strip()
        if not line:
            continue
        sp = line.find(" ")
        if sp < 0:
            continue
        oid_part = line[:sp]
        value_part = line[sp + 1:]
        idx = oid_part[len(oid) + 1:] if oid_part.startswith(oid + ".") else ""
        out.append((idx, value_part))
    return out

def _snmp_get(ctx, community, host, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    val = res.stdout.strip()
    if val.startswith('"') and val.endswith('"'):
        val = val[1:-1]
    return val

def _levels_tuple(params):
    lv = params.get("levels")
    if type(lv) == "list" and len(lv) >= 2:
        return (float(lv[0]), float(lv[1]))
    return None

def _grade_upper(value, params, upper_bound):
    lv = _levels_tuple(params)
    if lv == None:
        return "OK"
    w = lv[0]
    c = lv[1]
    if value >= c:
        return "CRIT"
    if value >= w:
        return "WARN"
    if upper_bound != None and value > upper_bound:
        return "CRIT"
    return "OK"

def _grade_lower(value, params, lower_bound):
    lv = _levels_tuple(params)
    if lv == None:
        return "OK"
    w = lv[0]
    c = lv[1]
    if value <= c:
        return "CRIT"
    if value <= w:
        return "WARN"
    if lower_bound != None and value < lower_bound:
        return "CRIT"
    return "OK"

def main(ctx, params):
    if params.get("_discover"):
        sys_descr = _snmp_get(ctx, "public", "localhost", ".1.3.6.1.2.1.1.1.0")
        if sys_descr == None:
            return {"changed": False, "msg": "discovery: no SNMP sysDescr", "data": {"discovery": []}}

        is_palo_alto = False
        palo_marker = "Palo Alto"
        if sys_descr.startswith(palo_marker):
            is_palo_alto = True

        table_rows = _snmp_walk_indexed(ctx, "public", "localhost", ".1.3.6.1.4.1.25461.2.1.2.5.1")
        table_exists = table_rows != None and len(table_rows) > 0

        if not (is_palo_alto and table_exists):
            return {"changed": False, "msg": "discovery: GlobalProtect not detected", "data": {"discovery": []}}

        return {
            "changed": False,
            "msg": "discovered 1 GlobalProtect service",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {
                            "utilization": {"levels": (80.0, 90.0)},
                            "active_tunnels": {"levels": (80.0, 90.0)},
                        },
                        "metrics": ["channel_utilization", "active_sessions"],
                    }
                ]
            },
        }

    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.25461.2.1.2.5.1"

    utilization = _snmp_get(ctx, community, host, base + ".1")
    max_tunnels = _snmp_get(ctx, community, host, base + ".2")
    active_tunnels = _snmp_get(ctx, community, host, base + ".3")

    if utilization == None or max_tunnels == None or active_tunnels == None:
        return {
            "changed": False,
            "msg": "no GlobalProtect utilization data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    util_val = 0.0
    max_val = 0
    active_val = 0.0
    if utilization.lstrip("-").isdigit():
        util_val = float(int(utilization))
    if max_tunnels.lstrip("-").isdigit():
        max_val = int(max_tunnels)
    if active_tunnels.lstrip("-").isdigit():
        active_val = float(int(active_tunnels))

    metrics = {
        "channel_utilization": util_val,
        "active_sessions": active_val,
    }

    u_state = _grade_upper(util_val, params.get("utilization", {}), 100.0)
    a_state = _grade_upper(active_val, params.get("active_tunnels", {}), float(max_val))

    worst = "OK"
    order = ["OK", "WARN", "CRIT", "UNKNOWN"]
    if order.index(u_state) > order.index(worst):
        worst = u_state
    if order.index(a_state) > order.index(worst):
        worst = a_state

    details = "Utilization: %d%%, Active sessions: %d, Max sessions: %d" % (
        int(util_val), int(active_val), max_val)

    return {
        "changed": False,
        "msg": details,
        "data": {
            "state": worst,
            "metrics": metrics,
            "details": details,
        },
    }