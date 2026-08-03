_MAP_SENSOR_TYPE = {"1": "temp", "2": "humidity", "3": "dewpoint"}
_MAP_UNITS = {"0": "c", "1": "f", "2": "k", "3": "percent"}
_MAP_STATES = {
    "0": (0, "OK"),
    "1": (3, "not available"),
    "2": (1, "over-flow"),
    "3": (1, "under-flow"),
    "4": (2, "error"),
}

BASE_OID = ".1.3.6.1.4.1.18248.20.1.2.1.1"


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        sysoid = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sysoid.rc != 0 or not sysoid.stdout.strip():
            return {"changed": False, "msg": "not a papouch th2e device", "data": {"discovery": []}}
        desc = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-OvQ", host, ".1.3.6.1.2.1.1.1.0"],
            mutates=False,
        )
        if desc.rc != 0 or "th2e" not in desc.stdout:
            return {"changed": False, "msg": "not a papouch th2e device", "data": {"discovery": []}}

        walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, BASE_OID + ".1"],
            mutates=False,
        )
        if walk.rc != 0 or not walk.stdout.strip():
            return {"changed": False, "msg": "no papouch th2e sensors", "data": {"discovery": []}}

        rows = {}
        for line in walk.stdout.splitlines():
            parts = line.split(None, 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            val = parts[1].strip()
            idx = oid[len(BASE_OID) + 2:]
            if not idx:
                continue
            rows.setdefault(idx, {})["1"] = val

        for line in walk.stdout.splitlines():
            parts = line.split(None, 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            idx = oid[len(BASE_OID) + 2:]
            col = oid[len(BASE_OID) + 1]
            if col == "3":
                rows.setdefault(idx, {})["3"] = parts[1].strip()

        discovery = []
        for idx, fields in rows.items():
            stype = _MAP_SENSOR_TYPE.get(fields.get("1", "1"), "unknown")
            if stype == "humidity":
                discovery.append({"item": "Sensor %s" % idx, "params": {"levels": (30.0, 35.0), "levels_lower": (12.0, 8.0)}, "metrics": ["humidity"]})
        return {"changed": False, "msg": "discovered %d humidity sensors" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")

    sysoid = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if sysoid.rc == 127:
        return {"changed": False, "msg": "snmp not available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if sysoid.rc != 0 or not sysoid.stdout.strip():
        return {"changed": False, "msg": "not a papouch th2e device", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    desc = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-OvQ", host, ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    if desc.rc != 0 or "th2e" not in desc.stdout:
        return {"changed": False, "msg": "not a papouch th2e device", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    idx = item.replace("Sensor ", "")
    state_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, BASE_OID + ".3." + idx],
        mutates=False,
    )
    reading_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, BASE_OID + ".2." + idx],
        mutates=False,
    )
    if state_res.rc != 0 or reading_res.rc != 0:
        return {"changed": False, "msg": "sensor %s not reachable" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state_code = state_res.stdout.strip()
    reading_raw = reading_res.stdout.strip()

    smap = _MAP_STATES.get(state_code)
    if smap == None:
        return {"changed": False, "msg": "unknown sensor state: %s" % state_code, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    dev_status_int, state_readable = smap
    reading_val = 0.0
    if reading_raw.lstrip("-").isdigit():
        reading_val = float(reading_raw) / 10.0

    levels = params.get("levels", (30.0, 35.0))
    levels_lower = params.get("levels_lower", (12.0, 8.0))

    warn_upper = levels[0] if type(levels) == "list" else levels[0]
    crit_upper = levels[1] if type(levels) == "list" else levels[1]
    warn_lower = levels_lower[0] if type(levels_lower) == "list" else levels_lower[0]
    crit_lower = levels_lower[1] if type(levels_lower) == "list" else levels_lower[1]

    if dev_status_int != 0:
        state = "UNKNOWN"
    elif reading_val >= crit_upper:
        state = "CRIT"
    elif reading_val >= warn_upper:
        state = "WARN"
    elif reading_val <= crit_lower:
        state = "CRIT"
    elif reading_val <= warn_lower:
        state = "WARN"
    else:
        state = "OK"

    return {"changed": False, "msg": "Status: %s, %f%%" % (state_readable, reading_val), "data": {"state": state, "metrics": {"humidity": reading_val}, "details": ""}}