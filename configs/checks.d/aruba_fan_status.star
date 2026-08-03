def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                       "-Oqn", params.get("host", "localhost"),
                       ".1.3.6.1.4.1.11.2.14.11.5.1.54.2.1.1"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}
        tray_map = {}
        type_map = {}
        state_map = {}
        fail_map = {}
        for line in res.stdout.splitlines():
            sp = line.split(" ", 1)
            if len(sp) < 2:
                continue
            oid = sp[0]
            val = sp[1]
            suffix = oid[len(".1.3.6.1.4.1.11.2.14.11.5.1.54.2.1.1") + 1:]
            parts = suffix.split(".")
            if len(parts) < 2:
                continue
            index = parts[0]
            col = parts[1]
            if col == "2":
                tray_map[index] = val
            elif col == "3":
                type_map[index] = val
            elif col == "4":
                state_map[index] = val
            elif col == "6":
                fail_map[index] = val
        out = []
        for index in sorted(set(list(tray_map.keys()) + list(type_map.keys()) +
                                list(state_map.keys()) + list(fail_map.keys()))):
            item = "%d" % int(index)
            out.append({"item": item, "params": {},
                        "metrics": ["fan_failures"]})
        return {"changed": False, "msg": "discovered %d fans" % len(out),
                "data": {"discovery": out}}
    item = params.get("item", "")
    tray_r = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                      "-Oqv", params.get("host", "localhost"),
                      ".1.3.6.1.4.1.11.2.14.11.5.1.54.2.1.1.%s.2" % item], mutates=False)
    type_r = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                      "-Oqv", params.get("host", "localhost"),
                      ".1.3.6.1.4.1.11.2.14.11.5.1.54.2.1.1.%s.3" % item], mutates=False)
    state_r = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                       "-Oqv", params.get("host", "localhost"),
                       ".1.3.6.1.4.1.11.2.14.11.5.1.54.2.1.1.%s.4" % item], mutates=False)
    fail_r = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                      "-Oqv", params.get("host", "localhost"),
                      ".1.3.6.1.4.1.11.2.14.11.5.1.54.2.1.1.%s.6" % item], mutates=False)
    if tray_r.rc != 0 or type_r.rc != 0 or state_r.rc != 0 or fail_r.rc != 0:
        return {"changed": False, "msg": "no fan data for item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    state_mapping = {
        "0": "CRIT",
        "1": "WARN",
        "2": "WARN",
        "3": "WARN",
        "4": "WARN",
        "5": "OK",
        "6": "OK",
    }
    type_map_names = {"0": "Unknown", "1": "MM", "2": "FM", "3": "IM",
                      "4": "PS", "5": "Rollup", "6": "Maxtype"}
    state_val = state_r.stdout.strip().strip('"')
    state = state_mapping.get(state_val, "UNKNOWN")
    fail_str = fail_r.stdout.strip().strip('"')
    failures = int(fail_str) if fail_str.isdigit() else 0
    type_val = type_r.stdout.strip().strip('"')
    type_name = type_map_names.get(type_val, "Unknown")
    tray_val = tray_r.stdout.strip().strip('"')
    msg = "Fan Status: %s, Type: %s, Tray: %s, Failures: %d" % (
        state_val, type_name, tray_val, failures)
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"fan_failures": failures}, "details": ""}}