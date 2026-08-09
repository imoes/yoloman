def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)


def _is_ups(ctx, host, community):
    # Probe for a real UPS via the standard UPS-MIB sysObjectID (1.3.6.1.2.1.1.2.0)
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if res.rc == 127:
        return False
    if res.rc != 0:
        return False
    sysoid = res.stdout.strip()
    if sysoid == "" or sysoid == "No response":
        return False
    return _matches_ups_oid(sysoid)


def _matches_ups_oid(sysoid):
    prefixes = [
        ".1.3.6.1.4.1.232.165.3",
        ".1.3.6.1.4.1.476.1.42",
        ".1.3.6.1.4.1.534.1",
        ".1.3.6.1.4.1.935",
        ".1.3.6.1.4.1.8072.3.2.10",
        ".1.3.6.1.4.1.2254.2.5",
        ".1.3.6.1.4.1.12551.4.0",
        ".1.3.6.1.4.1.43943",
        ".1.3.6.1.4.1.4555.1.1.7",
        ".1.3.6.1.4.1.42610.1.4.4",
    ]
    starts = [
        ".1.3.6.1.4.1.850",
        ".1.3.6.1.4.1.534.2",
        ".1.3.6.1.4.1.5491",
        ".1.3.6.1.4.1.705.1",
        ".1.3.6.1.4.1.818.1.100.1",
        ".1.3.6.1.4.1.935",
        ".1.3.6.1.4.1.534.10",
        ".1.3.6.1.2.1.33",
    ]
    for p in prefixes:
        if sysoid == p:
            return True
    for s in starts:
        if sysoid.startswith(s):
            return True
    return False


def _fetch_voltage_table(ctx, host, community):
    # Walk the input-voltage table: .1.3.6.1.2.1.33.1.3.3.1.<idx>, values in col 3
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.2.1.33.1.3.3.1.3"],
        mutates=False,
    )
    if res.rc != 0:
        return []
    rows = []
    for line in res.stdout.splitlines():
        # format: "<OID> <value>"
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid_full = parts[0]
        value = parts[1].strip()
        col_base = ".1.3.6.1.2.1.33.1.3.3.1.3"
        if not oid_full.startswith(col_base + "."):
            continue
        index = oid_full[len(col_base) + 1:]
        rows.append([index, value])
    return rows


def _discover(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    if not _is_ups(ctx, host, community):
        return {"changed": False, "msg": "no UPS detected", "data": {"discovery": []}}
    rows = _fetch_voltage_table(ctx, host, community)
    discovery = []
    for row in rows:
        item = row[0]
        value = row[1]
        if value == "" or value == "No response":
            continue
        if not _is_positive_int(value):
            continue
        discovery.append({
            "item": item,
            "metrics": ["in_voltage"],
            "params": {"levels_lower": (210.0, 180.0)},
        })
    return {
        "changed": False,
        "msg": "discovered %d items" % len(discovery),
        "data": {"discovery": discovery},
    }


def _check(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")
    if not _is_ups(ctx, host, community):
        return {
            "changed": False,
            "msg": "no UPS detected on host",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    rows = _fetch_voltage_table(ctx, host, community)
    if len(rows) == 0:
        return {
            "changed": False,
            "msg": "no input voltage values available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    value = None
    for row in rows:
        if row[0] == item:
            value = row[1]
            break
    if value == None:
        return {
            "changed": False,
            "msg": "no such phase: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    if not _is_positive_int(value):
        return {
            "changed": False,
            "msg": "invalid voltage value for phase %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    v = int(value)
    levels_lower = params.get("levels_lower", (210.0, 180.0))
    levels_upper = params.get("levels_upper", (None, None))
    warn_l = levels_lower[0]
    crit_l = levels_lower[1]
    state = _grade_lower(v, warn_l, crit_l)
    return {
        "changed": False,
        "msg": "In voltage phase %s: %dV" % (item, v),
        "data": {"state": state, "metrics": {"in_voltage": v}, "details": ""},
    }


def _grade_lower(value, warn_l, crit_l):
    if crit_l != None and value <= crit_l:
        return "CRIT"
    if warn_l != None and value <= warn_l:
        return "WARN"
    return "OK"


def _is_positive_int(s):
    if s == None or s == "":
        return False
    if not s.lstrip("-").isdigit():
        return False
    return int(s) > 0