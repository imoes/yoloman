def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Detection: check sysDescr.0 for "fr5000"
    detect_oid = ".1.3.6.1.2.1.1.1.0"
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, detect_oid], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "snmpget not installed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0:
        return {"changed": False, "msg": "device not responding or not an ICOM repeater", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.stdout.find("fr5000") == -1:
        return {"changed": False, "msg": "not an ICOM FR5000 repeater", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        # Walk the repeater table to find the PS voltage row
        col2 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.2021.8.1.2"], mutates=False)
        col101 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.2021.8.1.101"], mutates=False)
        if col2.rc != 0 or col101.rc != 0:
            return {"changed": False, "msg": "could not walk repeater table", "data": {"discovery": [], "host_labels": {}}}

        col2_map = {}
        for line in col2.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            idx = oid[len(".1.3.6.1.4.1.2021.8.1.2") + 1:]
            col2_map[idx] = parts[1]

        col101_map = {}
        for line in col101.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            idx = oid[len(".1.3.6.1.4.1.2021.8.1.101") + 1:]
            col101_map[idx] = parts[1]

        ps_voltage = None
        for idx in col2_map:
            if col2_map[idx] == "Power-supply voltage":
                raw = col101_map.get(idx, "")
                if len(raw) > 0:
                    try_val = raw[:-1]
                    ps_voltage = float(try_val) if try_val.replace(".", "", 1).isdigit() else None
                    if ps_voltage != None:
                        break

        if ps_voltage != None:
            entry = {"item": "", "params": {"levels_lower": [13.5, 13.2], "levels_upper": [14.1, 14.4]}, "metrics": ["voltage"]}
            return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": [entry], "host_labels": {}}}
        return {"changed": False, "msg": "no PS voltage data", "data": {"discovery": [], "host_labels": {}}}

    # Check mode
    col2 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.2021.8.1.2"], mutates=False)
    col101 = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.2021.8.1.101"], mutates=False)
    if col2.rc != 0 or col101.rc != 0:
        return {"changed": False, "msg": "could not read repeater table", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    col2_map = {}
    for line in col2.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        idx = oid[len(".1.3.6.1.4.1.2021.8.1.2") + 1:]
        col2_map[idx] = parts[1]

    col101_map = {}
    for line in col101.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        idx = oid[len(".1.3.6.1.4.1.2021.8.1.101") + 1:]
        col101_map[idx] = parts[1]

    ps_voltage = None
    for idx in col2_map:
        if col2_map[idx] == "Power-supply voltage":
            raw = col101_map.get(idx, "")
            if len(raw) > 0:
                try_val = raw[:-1]
                ps_voltage = float(try_val) if try_val.replace(".", "", 1).isdigit() else None
                if ps_voltage != None:
                    break

    if ps_voltage == None:
        return {"changed": False, "msg": "no power-supply voltage found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    levels_lower = params.get("levels_lower", [13.5, 13.2])
    levels_upper = params.get("levels_upper", [14.1, 14.4])
    warn_lower = levels_lower[0]
    crit_lower = levels_lower[1]
    warn_upper = levels_upper[0]
    crit_upper = levels_upper[1]

    if ps_voltage >= crit_upper or ps_voltage <= crit_lower:
        state = "CRIT"
    elif ps_voltage >= warn_upper or ps_voltage <= warn_lower:
        state = "WARN"
    else:
        state = "OK"

    msg = "%f V" % ps_voltage
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": {"voltage": ps_voltage}, "details": ""}}