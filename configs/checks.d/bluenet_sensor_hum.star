def main(ctx, params):
    if params.get("_discover"):
        sys_res = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"),
             ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sys_res.rc != 0:
            return {"changed": False, "msg": "no SNMP agent reachable",
                    "data": {"discovery": [], "host_labels": {}}}
        sys_oid = sys_res.stdout.strip().lower()
        if not sys_oid.startswith(".1.3.6.1.4.1.21695.1"):
            return {"changed": False, "msg": "not a Bluenet device",
                    "data": {"discovery": [], "host_labels": {}}}
        walk_res = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
             "-Oqn", params.get("host", "localhost"),
             ".1.3.6.1.4.1.21695.1.10.7.3.1.2"],
            mutates=False,
        )
        if walk_res.rc != 0 or not walk_res.stdout.strip():
            return {"changed": False, "msg": "no Bluenet sensors found",
                    "data": {"discovery": []}}
        discovery = []
        for line in walk_res.stdout.splitlines():
            space = line.find(" ")
            if space == -1:
                continue
            oid = line[:space].strip()
            value = line[space + 1:].strip()
            column_oid = ".1.3.6.1.4.1.21695.1.10.7.3.1.2"
            index = oid[len(column_oid) + 1:]
            if not index:
                continue
            sensor_type = value
            if sensor_type != "2":
                continue
            sensor_id_raw = str(index)
            item_name = "internal" if sensor_id_raw == "0" else ("external " + sensor_id_raw)
            discovery.append({
                "item": item_name,
                "params": {"levels": (60, 65), "levels_lower": (40, 35)},
                "metrics": ["humidity"],
            })
        return {"changed": False,
                "msg": "discovered %d humidity sensors" % len(discovery),
                "data": {"discovery": discovery}}
    item = params.get("item", "")
    if item == "internal":
        index = "0"
    elif item.startswith("external "):
        index = item[len("external "):]
    else:
        return {"changed": False, "msg": "unknown item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sensor_type_res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"),
         ".1.3.6.1.4.1.21695.1.10.7.3.1.2." + index],
        mutates=False,
    )
    if sensor_type_res.rc != 0:
        return {"changed": False, "msg": "no data for sensor " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sensor_type = sensor_type_res.stdout.strip()
    if sensor_type != "2":
        return {"changed": False,
                "msg": "item %s is not a humidity sensor (type %s)" % (item, sensor_type),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    hum_res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"),
         ".1.3.6.1.4.1.21695.1.10.7.3.1.5." + index],
        mutates=False,
    )
    if hum_res.rc != 0:
        return {"changed": False, "msg": "no humidity data for sensor " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    hum_raw = hum_res.stdout.strip()
    hum_int = int(hum_raw) if hum_raw.isdigit() else 0
    humidity = float(hum_int) / 10.0
    levels = params.get("levels", (60, 65))
    levels_lower = params.get("levels_lower", (40, 35))
    warn_high = levels[0] if len(levels) > 0 else 60
    crit_high = levels[1] if len(levels) > 1 else 65
    warn_low = levels_lower[0] if len(levels_lower) > 0 else 40
    crit_low = levels_lower[1] if len(levels_lower) > 1 else 35
    if (humidity >= crit_high) or (humidity <= crit_low):
        state = "CRIT"
    elif (humidity >= warn_high) or (humidity <= warn_low):
        state = "WARN"
    else:
        state = "OK"
    return {"changed": False,
            "msg": "%s humidity: %f%%" % (item, humidity),
            "data": {"state": state,
                     "metrics": {"humidity": humidity},
                     "details": "Humidity reading: %f%% (warn low %f%% / crit low %f%%, warn high %f%% / crit high %f%%)" % (
                         humidity, warn_low, crit_low, warn_high, crit_high)}}