NETBOTZ_FLUID_BASE = ".1.3.6.1.4.1.318.1.1.10.4.7.6.1"
FLUID_STATE_NAMES = {
    1: "FLUIDLEAK",
    2: "NOFLUID",
    3: "UNKNOWN",
}


def _snmp_walk_fluid(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, NETBOTZ_FLUID_BASE],
        mutates=False,
    )
    if res.rc != 0:
        return None
    sensors = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        value = line[sp + 1:]
        suffix = oid[len(NETBOTZ_FLUID_BASE) + 1:]
        parts = suffix.split(".")
        if len(parts) < 4:
            continue
        col = parts[0]
        if col not in ("1", "2", "3", "5"):
            continue
        idx_key = ".".join(parts[1:])
        sensors.setdefault(idx_key, {})[col] = value
    return sensors


def _is_apc(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    if res.rc != 0:
        return False
    return "apc" in res.stdout.lower()


def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        if not _is_apc(ctx, params):
            return {"changed": False, "msg": "APC device not found", "data": {"discovery": []}}

        walked = _snmp_walk_fluid(ctx, params)
        if walked == None:
            return {"changed": False, "msg": "snmpwalk failed", "data": {"discovery": []}}

        discovery = []
        for idx, cols in walked.items():
            module_idx = cols.get("1", "?")
            sensor_idx = cols.get("2", "?")
            sensor_name = cols.get("3", "?")
            state_col = cols.get("5", None)
            if state_col == None:
                continue
            item = "%s %s/%s" % (sensor_name, module_idx, sensor_idx)
            discovery.append({"item": item, "params": {}, "metrics": []})
        return {
            "changed": False,
            "msg": "discovered %d fluid detectors" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item specified", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    walked = _snmp_walk_fluid(ctx, params)
    if walked == None:
        return {"changed": False, "msg": "snmpwalk failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    found_key = None
    for idx, cols in walked.items():
        module_idx = cols.get("1", "?")
        sensor_idx = cols.get("2", "?")
        sensor_name = cols.get("3", "?")
        candidate = "%s %s/%s" % (sensor_name, module_idx, sensor_idx)
        if candidate == item:
            found_key = idx
            break

    if found_key == None:
        return {"changed": False, "msg": "fluid detector not found: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    cols = walked[found_key]
    raw_state = cols.get("5", "")
    if not raw_state or not raw_state.isdigit():
        return {"changed": False, "msg": "no fluid state data for " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state_val = int(raw_state)
    if state_val == 1:
        state = "CRIT"
        summary = "Leak detected"
    elif state_val == 2:
        state = "OK"
        summary = "No leak detected"
    elif state_val == 3:
        state = "UNKNOWN"
        summary = "State Unknown"
    else:
        state = "UNKNOWN"
        summary = "Unknown fluid state (%s)" % raw_state

    return {"changed": False, "msg": summary, "data": {"state": state, "metrics": {}, "details": ""}}