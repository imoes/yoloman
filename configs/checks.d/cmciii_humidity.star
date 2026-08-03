def discover_cmciii_sensors(sensors):
    out = []
    for id_ in sorted(sensors.keys()):
        out.append({
            "item": id_,
            "params": {"_item_key": id_},
            "metrics": ["humidity"],
        })
    return out


def get_sensor(item, params, sensors):
    if params and params.get("_item_key") != None and params.get("_item_key") != "":
        return sensors.get(params.get("_item_key"))
    return sensors.get(item)


def safe_float(s):
    if s == None or s == "":
        return None
    parts = s.split(".")
    ok = True
    for p in parts:
        if not p.isdigit():
            ok = False
            break
    if ok:
        return float(s)
    return None


def get_humidity_section(ctx, host, community):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
         ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2"],
        mutates=False,
    )
    if res.rc != 0:
        return None
    lines = res.stdout.splitlines()
    sensors = {}
    current_id = None
    for line in lines:
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        val = parts[1]
        suffix = oid[len(".1.3.6.1.4.1.2606.7.4.2.2.1.3.2"):]
        idx_parts = suffix.split(".")
        if len(idx_parts) < 2:
            continue
        sensor_index = idx_parts[1]
        col = idx_parts[0]
        if col == "3":
            current_id = val
            if current_id not in sensors:
                sensors[current_id] = {"_index_": sensor_index}
            sensors[current_id]["DescName"] = val
        elif col == "6":
            if current_id != None:
                sensors[current_id]["Status"] = val
        elif col == "7":
            if current_id != None:
                sensors[current_id]["_location_"] = val
        elif col == "9":
            if current_id != None:
                sensors[current_id]["Value"] = val
    return {"humidity": sensors}


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    if params.get("_discover"):
        sys_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-OvQ", host, ".1.3.6.1.2.1.1.1.0"],
            mutates=False,
        )
        if sys_res.rc != 0:
            return {"changed": False, "msg": "no rittal lcp found",
                    "data": {"discovery": []}}
        sys_descr = sys_res.stdout.strip()
        if "Rittal LCP" not in sys_descr:
            return {"changed": False, "msg": "no rittal lcp found",
                    "data": {"discovery": []}}
        section = get_humidity_section(ctx, host, community)
        if section == None:
            return {"changed": False, "msg": "no humidity sensors found",
                    "data": {"discovery": []}}
        sensors = section.get("humidity", {})
        if len(sensors) == 0:
            return {"changed": False, "msg": "no humidity sensors found",
                    "data": {"discovery": []}}
        discovery = discover_cmciii_sensors(sensors)
        return {"changed": False, "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}
    item = params.get("item", "")
    section = get_humidity_section(ctx, host, community)
    if section == None or section.get("humidity") == None:
        return {"changed": False, "msg": "no rittal lcp humidity sensors found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sensors = section["humidity"]
    if len(sensors) == 0:
        return {"changed": False, "msg": "no rittal lcp humidity sensors found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    entry = get_sensor(item, params, sensors)
    if entry == None:
        return {"changed": False, "msg": "no such sensor: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    state_readable = entry.get("Status", "UNKNOWN")
    state = "OK" if state_readable == "OK" else "CRIT"
    value_str = entry.get("Value", "")
    value = safe_float(value_str)
    warn = params.get("warn")
    crit = params.get("crit")
    if value != None and warn != None and crit != None:
        if value >= crit:
            state = "CRIT"
        elif value >= warn:
            state = "WARN"
        else:
            state = "OK"
    metrics = {}
    if value != None:
        metrics["humidity"] = value
    return {"changed": False,
            "msg": "Status: %s, Humidity: %s %%" % (state_readable, value_str),
            "data": {"state": state, "metrics": metrics,
                     "details": "sensor " + item}}