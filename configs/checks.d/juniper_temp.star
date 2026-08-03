def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        sys_oid = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if sys_oid.rc != 0:
            return {"changed": False, "msg": "not a juniper device", "data": {"discovery": []}}
        sys_val = sys_oid.stdout.strip()
        if not (sys_val.startswith(".1.3.6.1.4.1.2636.1.1.1.2") or sys_val.startswith(".1.3.6.1.4.1.2636.1.1.1.4")):
            return {"changed": False, "msg": "not a juniper device", "data": {"discovery": []}}
        descr_walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.2636.3.1.13.1.5.7"], mutates=False)
        temp_walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.2636.3.1.13.1.7.7"], mutates=False)
        descr_map = {}
        for line in descr_walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid, value = parts[0], parts[1]
            index = oid[len(".1.3.6.1.4.1.2636.3.1.13.1.5.7") + 1:]
            value = value.strip().strip('"').replace(":", "").replace("/*", "").replace("@ ", "").strip()
            descr_map[index] = value
        temp_map = {}
        for line in temp_walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid, value = parts[0], parts[1]
            index = oid[len(".1.3.6.1.4.1.2636.3.1.13.1.7.7") + 1:]
            try_val = float(value)
            if try_val > 0:
                temp_map[index] = try_val
        discovery = []
        for index in descr_map:
            if index in temp_map:
                discovery.append({"item": descr_map[index], "params": {"levels": (55.0, 60.0)}, "metrics": ["temperature"]})
        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery}}
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    sys_oid = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if sys_oid.rc != 0:
        return {"changed": False, "msg": "not a juniper device", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sys_val = sys_oid.stdout.strip()
    if not (sys_val.startswith(".1.3.6.1.4.1.2636.1.1.1.2") or sys_val.startswith(".1.3.6.1.4.1.2636.1.1.1.4")):
        return {"changed": False, "msg": "not a juniper device", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    descr_walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.2636.3.1.13.1.5.7"], mutates=False)
    temp_walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.2636.3.1.13.1.7.7"], mutates=False)
    descr_map = {}
    for line in descr_walk.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid, value = parts[0], parts[1]
        index = oid[len(".1.3.6.1.4.1.2636.3.1.13.1.5.7") + 1:]
        value = value.strip().strip('"').replace(":", "").replace("/*", "").replace("@ ", "").strip()
        descr_map[index] = value
    temp_map = {}
    for line in temp_walk.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid, value = parts[0], parts[1]
        index = oid[len(".1.3.6.1.4.1.2636.3.1.13.1.7.7") + 1:]
        try_val = float(value)
        if try_val > 0:
            temp_map[index] = try_val
    target_index = None
    for index, description in descr_map.items():
        if description == item:
            target_index = index
            break
    if target_index == None or target_index not in temp_map:
        return {"changed": False, "msg": "no such temperature sensor: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    temperature = temp_map[target_index]
    levels = params.get("levels", (55.0, 60.0))
    warn = levels[0]
    crit = levels[1]
    state = "CRIT" if temperature >= crit else ("WARN" if temperature >= warn else "OK")
    return {"changed": False, "msg": "Temperature %s: %f C" % (item, temperature), "data": {"state": state, "metrics": {"temperature": temperature}, "details": ""}}