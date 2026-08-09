def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)


def _probe_fans(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base = ".1.3.6.1.4.1.2272.1.101.1.1.4.1"
    cols = ["3", "4", "5", "6"]
    table = {}
    for col in cols:
        oid = base + "." + col
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
            mutates=False,
        )
        if res.rc != 0:
            return None
        for line in res.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            line_oid = line[:sp]
            val = line[sp + 1:]
            idx = line_oid[len(oid) + 1:]
            if idx not in table:
                table[idx] = {}
            table[idx][col] = val
    return table


_MAP_FAN_STATUS = {
    "1": ("UNKNOWN", "unknown - status can not be determined"),
    "2": ("OK", "up - present and supplying power"),
    "3": ("CRIT", "down - present, but failure indicated"),
}

_MAP_FAN_SPEED = {
    "1": "low",
    "2": "medium",
    "3": "high",
}


def _discover(ctx, params):
    table = _probe_fans(ctx, params)
    discovery = []
    if table != None:
        for idx in table:
            entry = table[idx]
            desc = entry.get("3", "")
            lower = params.get("lower", (2000, 1000))
            upper = params.get("upper", (8000, 8400))
            discovery.append({
                "item": desc,
                "params": {"lower": list(lower), "upper": list(upper)},
                "metrics": ["rpm"],
            })
    return {
        "changed": False,
        "msg": "discovered %d fans" % len(discovery),
        "data": {"discovery": discovery},
    }


def _check(ctx, params):
    item = params.get("item", "")
    table = _probe_fans(ctx, params)
    if table == None:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    found = None
    for idx in table:
        entry = table[idx]
        if entry.get("3", "") == item:
            found = entry
            break
    if found == None:
        return {
            "changed": False,
            "msg": "no such fan: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    status = found.get("4", "")
    st, st_readable = _MAP_FAN_STATUS.get(
        status, ("UNKNOWN", "Unknown fan status: %s" % status),
    )
    speed = _MAP_FAN_SPEED.get(found.get("5", ""), "unknown")
    msg = "Fan status: %s; Fan speed: %s" % (st_readable, speed)
    metrics = {}
    details = ""
    rpm_raw = found.get("6", "")
    if rpm_raw != None and rpm_raw != "":
        rpm = float(rpm_raw)
        metrics["rpm"] = rpm
        lower = params.get("lower", (2000, 1000))
        warn_l = lower[0] if len(lower) > 0 else 2000
        crit_l = lower[1] if len(lower) > 1 else 1000
        upper = params.get("upper", (8000, 8400))
        warn_u = upper[0] if len(upper) > 0 else 8000
        crit_u = upper[1] if len(upper) > 1 else 8400
        if (rpm >= crit_u) or (rpm <= crit_l):
            st = "CRIT"
        elif (rpm >= warn_u) or (rpm <= warn_l):
            st = "WARN"
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": st, "metrics": metrics, "details": details},
    }