def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)


def _saveint(s):
    stripped = s.strip().strip('"')
    if stripped.lstrip("-").isdigit():
        return int(stripped)
    return 0


def _discover(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    sys_oid_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if sys_oid_res.rc != 0:
        return {"changed": False, "msg": "not a Socomec UPS", "data": {"discovery": []}}

    sys_oid = sys_oid_res.stdout.strip()
    if not sys_oid.startswith(".1.3.6.1.4.1.4555.1.1.1"):
        return {"changed": False, "msg": "not a Socomec UPS", "data": {"discovery": []}}

    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.4555.1.1.1.1.3.3.1.1"],
        mutates=False,
    )
    if res.rc != 0 and res.rc != 128:
        return {"changed": False, "msg": "failed to walk IN voltage table", "data": {"discovery": []}}

    lines = res.stdout.splitlines()
    if len(lines) == 0:
        return {"changed": False, "msg": "no IN voltage phases found", "data": {"discovery": []}}

    out = []
    for line in lines:
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0]
        value = parts[1].strip().strip('"')
        index = oid[len(".1.3.6.1.4.1.4555.1.1.1.1.3.3.1.1") + 1:]
        if not index:
            continue
        out.append({
            "item": value,
            "params": {"levels_lower": [210.0, 180.0]},
            "metrics": ["in_voltage"],
        })
    return {
        "changed": False,
        "msg": "discovered %d items" % len(out),
        "data": {"discovery": out},
    }


def _check(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")

    sys_oid_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if sys_oid_res.rc != 0:
        return {
            "changed": False,
            "msg": "no Socomec UPS found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    name_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.4555.1.1.1.1.3.3.1.1"],
        mutates=False,
    )
    base = ".1.3.6.1.4.1.4555.1.1.1.1.3.3.1"
    col_name = base + ".1"
    col_voltage = base + ".2"

    if name_res.rc != 0:
        return {
            "changed": False,
            "msg": "failed to retrieve IN voltage table",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    target_index = None
    for line in name_res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0]
        value = parts[1].strip().strip('"')
        index = oid[len(col_name) + 1:]
        if value == item:
            target_index = index
            break

    if target_index == None:
        return {
            "changed": False,
            "msg": "no such phase: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    voltage_oid = col_voltage + "." + target_index
    voltage_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, voltage_oid],
        mutates=False,
    )
    if voltage_res.rc != 0:
        return {
            "changed": False,
            "msg": "no voltage data for phase " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    voltage_raw = voltage_res.stdout.strip().strip('"')
    voltage_tenths = _saveint(voltage_raw)
    voltage = voltage_tenths // 10

    levels = params.get("levels_lower", [210.0, 180.0])
    warn = levels[0] if len(levels) >= 1 else 210.0
    crit = levels[1] if len(levels) >= 2 else 180.0

    if voltage == 0:
        state = "UNKNOWN"
    elif voltage <= crit:
        state = "CRIT"
    elif voltage <= warn:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "%s %fV" % (item, voltage),
        "data": {
            "state": state,
            "metrics": {"in_voltage": voltage},
            "details": "",
        },
    }