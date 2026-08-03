def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")

        # Probe for the real Rittal device via SNMP sysObjectID
        sysid = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if sysid.rc != 0:
            return {"changed": False, "msg": "no Rittal CMCTC LCP device found", "data": {"discovery": []}}

        sensors = _gather_humidity_sensors(ctx, host, community)
        out = []
        for item in sensors:
            out.append({"item": item, "params": {}, "metrics": ["humidity"]})
        return {"changed": False, "msg": "discovered %d humidity sensors" % len(out), "data": {"discovery": out}}

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    sensors = _gather_humidity_sensors(ctx, host, community)
    sensor = sensors.get(item)
    if sensor == None:
        return {"changed": False, "msg": "no such humidity sensor: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # map_sensor_state
    sensor_state_map = {
        "1": 3, "2": 2, "3": 1, "4": 0, "5": 2, "6": 0, "7": 1, "8": 2, "9": 2, "10": 2,
    }
    state_code = int(sensor_state_map.get(sensor["status"], "3"))

    reading = sensor["reading"]
    high = sensor["high"]
    low = sensor["low"]
    warn = sensor["warn"]
    desc = sensor["description"]

    extra_info = ""
    if desc != "":
        extra_info += "[%s] " % desc

    extra_info += "%d%%" % int(reading)

    # device levels
    extra_state = 0
    has_levels = (low != high) and (low < high)
    if has_levels:
        if reading >= high or reading <= low:
            extra_state = 2
            extra_info += " (device lower/upper crit at %d/%d%%)" % (int(low), int(high))

    state = "OK"
    if extra_state == 2:
        state = "CRIT"
    elif extra_state == 1:
        state = "WARN"
    if state_code >= 2:
        state = "CRIT"
    elif state_code == 1 and state == "OK":
        state = "WARN"

    return {"changed": False, "msg": extra_info, "data": {"state": state, "metrics": {"humidity": reading}, "details": ""}}


def _gather_humidity_sensors(ctx, host, community):
    sensors = {}
    trees = ["3", "4", "5", "6"]
    column_base = "5.2.1"
    desc_oid_suffix = "7.2.1.2"
    for tree in trees:
        # Walk the table using the index column to get row indices and typeids
        oid = ".1.3.6.1.4.1.2606.4.2." + tree + "." + column_base + ".1.2"
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid], mutates=False)
        if res.rc != 0:
            continue
        rows = {}
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid_full = parts[0]
            val = parts[1].strip()
            idx = oid_full[len(oid) + 1:]
            rows[idx] = val

        for idx, typeid in rows.items():
            typeid = typeid.strip()
            if typeid != "12":
                continue
            # typeid 12 = humidity, no name prefix
            item = tree + "." + idx
            s = _read_sensor_row(ctx, host, community, tree, idx)
            if s != None:
                s["type_"] = "humidity"
                sensors[item] = s
    return sensors


def _read_sensor_row(ctx, host, community, tree, idx):
    base = ".1.3.6.1.4.1.2606.4.2." + tree + ".5.2.1"
    oids = {
        "status": base + ".1." + idx,
        "reading": base + ".4." + idx,
        "high": base + ".5." + idx,
        "low": base + ".6." + idx,
        "warn": base + ".7." + idx,
        "description": base + ".8." + idx,
    }
    out = {}
    for k in ["status", "reading", "high", "low", "warn", "description"]:
        v = _snmpget_scalar(ctx, host, community, oids[k])
        if v == None:
            return None
        out[k] = v
    out["status"] = str(int(out["status"]))
    return out


def _snmpget_scalar(ctx, host, community, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return None
    return res.stdout.strip()