def main(ctx, params):
    if params.get("_discover"):
        return discover(ctx, params)
    return check(ctx, params)


def probe_socomec_oid(ctx, params, oid):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0 or res.skipped:
        return None
    return res.stdout.strip()


def probe_table(ctx, params, column_oid):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, column_oid],
        mutates=False,
    )
    if res.rc != 0 or res.skipped:
        return []
    rows = []
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid_full = parts[0]
        value = parts[1]
        index = oid_full[len(column_oid) + 1:]
        if index == "":
            continue
        rows.append((index, value))
    return rows


def discover(ctx, params):
    sys_oid = probe_socomec_oid(ctx, params, ".1.3.6.1.2.1.1.2.0")
    if sys_oid == None or sys_oid != ".1.3.6.1.4.1.4555.1.1.1":
        return {"changed": False, "msg": "not a Socomex UPS", "data": {"discovery": []}}
    rows = probe_table(ctx, params, ".1.3.6.1.4.1.4555.1.1.1.1.4.4.1.1")
    if not rows:
        return {"changed": False, "msg": "not a Socomex UPS", "data": {"discovery": []}}
    discovery = [
        {"item": idx, "params": {"levels_lower": (210.0, 180.0)}, "metrics": ["out_voltage"]}
        for idx, val in rows
        if saveint(val) > 0
    ]
    return {
        "changed": False,
        "msg": "discovered %d items" % len(discovery),
        "data": {"discovery": discovery},
    }


def check(ctx, params):
    item = params.get("item", "")
    sys_oid = probe_socomec_oid(ctx, params, ".1.3.6.1.2.1.1.2.0")
    if sys_oid == None or sys_oid != ".1.3.6.1.4.1.4555.1.1.1":
        return {
            "changed": False,
            "msg": "not a Socomex UPS",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    rows = probe_table(ctx, params, ".1.3.6.1.4.1.4555.1.1.1.1.4.4.1.1")
    if not rows:
        return {
            "changed": False,
            "msg": "not a Socomex UPS",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    found = False
    out_val = 0
    for idx, val in rows:
        if idx == item:
            found = True
            out_val = saveint(val) // 10
            break
    if not found:
        return {
            "changed": False,
            "msg": "no such item: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    levels = params.get("levels_lower", params.get("levels", (210.0, 180.0)))
    warn = levels[0] if (type(levels) == "list" or type(levels) == "tuple") and len(levels) >= 1 else 210.0
    crit = levels[1] if (type(levels) == "list" or type(levels) == "tuple") and len(levels) >= 2 else 180.0
    if out_val <= crit:
        state = "CRIT"
    elif out_val <= warn:
        state = "WARN"
    else:
        state = "OK"
    return {
        "changed": False,
        "msg": "Out voltage: %dV" % out_val,
        "data": {
            "state": state,
            "metrics": {"out_voltage": out_val},
            "details": "phase %s" % item,
        },
    }


def saveint(i):
    if i == None or i == "":
        return 0
    s = i.strip()
    if s.lstrip("-").isdigit():
        return int(s)
    return 0