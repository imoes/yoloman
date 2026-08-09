def main(ctx, params):
    base_oid = ".1.3.6.1.4.1.6302.2.1.2"
    temp_col_oid = base_oid + ".7"
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Probe whether this is an Emerson device by reading the sysDescr OID
    descr = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.6302.2.1.1.1.0"],
        mutates=False,
    )
    if descr.rc != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "Emerson device not reachable via SNMP",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "no emerson_temp sensor found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    descr_val = descr.stdout
    if not descr_val.startswith("Emerson Network Power"):
        if params.get("_discover"):
            return {"changed": False, "msg": "not an Emerson device",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "no emerson_temp sensor found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        # Walk the temperature column OID to discover sensors
        walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, temp_col_oid],
            mutates=False,
        )
        sensors = []
        if walk.rc == 0:
            for line in walk.stdout.splitlines():
                if not line.strip():
                    continue
                parts = line.split(" ", 1)
                if len(parts) < 2:
                    continue
                oid = parts[0]
                val_str = parts[1]
                idx = oid[len(temp_col_oid) + 1:]
                if not idx:
                    continue
                val = _parse_int(val_str)
                if val == None:
                    continue
                if val >= -273000:
                    sensors.append({
                        "item": idx,
                        "params": {"warn": 40.0, "crit": 50.0},
                        "metrics": ["temperature"],
                    })
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(sensors),
            "data": {"discovery": sensors},
        }

    # Check mode: check a specific sensor
    item = params.get("item", "")
    warn = params.get("warn", 40.0)
    if type(params).get("params") == "dict":
        levels = params.get("levels")
        if levels != None:
            warn = levels[0]
            crit = levels[1]
    crit = params.get("crit", 50.0)

    full_oid = temp_col_oid + "." + item
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, full_oid],
        mutates=False,
    )
    if res.rc != 0:
        return {"changed": False, "msg": "no emersion_temp sensor found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw = _parse_int(res.stdout)
    if raw == None:
        return {"changed": False, "msg": "invalid temperature value for sensor " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if raw < -273000:
        return {"changed": False, "msg": "Temperature " + item + ": Sensor offline",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "sensor offline"}}

    temp = float(raw) / 1000.0
    state = "OK"
    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"

    return {
        "changed": False,
        "msg": "Temperature %s: %f C" % (item, temp),
        "data": {
            "state": state,
            "metrics": {"temperature": temp},
            "details": "",
        },
    }


def _parse_int(s):
    s = s.strip()
    if not s:
        return None
    neg = False
    body = s
    if s[0] == "-":
        neg = True
        body = s[1:]
    elif s[0] == "+":
        body = s[1:]
    if not body or not body.isdigit():
        return None
    v = 0
    for ch in body:
        v = v * 10 + (ord(ch) - ord("0"))
    return v if not neg else -v