def _get_item_from_key(key):
    return key.replace(" Air Temperature", "")

def _get_item_data(item, sensors):
    for key, data in sensors.items():
        if _get_item_from_key(key) == item:
            return data
    return None

def _temperature_to_celsius(reading, unit):
    cleaned = unit.replace("deg ", "").lower()
    if cleaned == "c" or cleaned == "%":
        return reading
    if cleaned == "f":
        return (reading - 32) * (5.0 / 9.0)
    if cleaned == "k":
        return reading - 273.15
    return reading

def _parse_float(value):
    stripped = value.strip().lstrip("-")
    int_part = stripped.split(".")[0]
    frac_part = stripped.split(".")[1] if "." in stripped else ""
    valid = int_part.isdigit() and (frac_part == "" or frac_part.isdigit())
    return float(value) if valid and stripped != "" else None

def _parse_liebert_snmp(values):
    parsed = {}
    used_names = set()
    label_oids = [
        "1.3.6.1.4.1.476.1.42.3.9.20.1.10.1.2.1.4291",
        "1.3.6.1.4.1.476.1.42.3.9.20.1.20.1.2.1.4291",
        "1.3.6.1.4.1.476.1.42.3.9.20.1.30.1.2.1.4291",
        "1.3.6.1.4.1.476.1.42.3.9.20.1.10.1.2.1.5002",
        "1.3.6.1.4.1.476.1.42.3.9.20.1.20.1.2.1.5002",
        "1.3.6.1.4.1.476.1.42.3.9.20.1.30.1.2.1.5002",
    ]
    for i in range(0, len(label_oids), 3):
        if i + 2 >= len(label_oids):
            break
        label_oid = label_oids[i]
        value_oid = label_oids[i + 1]
        unit_oid = label_oids[i + 2]
        label = values.get(label_oid, "")
        value = values.get(value_oid, "")
        unit = values.get(unit_oid, "")
        if not label:
            continue
        name = label
        counter = 2
        while name in used_names:
            name = "%s %d" % (label, counter)
            counter = counter + 1
        used_names.add(name)
        fval = _parse_float(value)
        if fval == None:
            parsed[name] = (value, unit)
        else:
            parsed[name] = (fval, unit)
    return parsed

def _fetch_liebert_sensors(ctx, host, community):
    label_oids = [
        "1.3.6.1.4.1.476.1.42.3.9.20.1.10.1.2.1.4291",
        "1.3.6.1.4.1.476.1.42.3.9.20.1.20.1.2.1.4291",
        "1.3.6.1.4.1.476.1.42.3.9.20.1.30.1.2.1.4291",
        "1.3.6.1.4.1.476.1.42.3.9.20.1.10.1.2.1.5002",
        "1.3.6.1.4.1.476.1.42.3.9.20.1.20.1.2.1.5002",
        "1.3.6.1.4.1.476.1.42.3.9.20.1.30.1.2.1.5002",
    ]
    values = {}
    for oid in label_oids:
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
        if res.rc == 0:
            values[oid] = res.stdout.strip()
        else:
            values[oid] = ""
    return _parse_liebert_snmp(values)

def _probe_liebert(ctx, host, community):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, "1.3.6.1.2.1.1.2.0"], mutates=False)
    if res.rc == 127:
        return False
    if res.rc != 0:
        return False
    sys_oid = res.stdout.strip()
    return sys_oid.startswith("1.3.6.1.4.1.476.1.42")

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    if params.get("_discover"):
        if not _probe_liebert(ctx, host, community):
            return {"changed": False, "msg": "no Liebert device found",
                    "data": {"discovery": [], "host_labels": {}}}
        sensors = _fetch_liebert_sensors(ctx, host, community)
        discovery = []
        seen = set()
        for key, data in sensors.items():
            value, unit = data
            if "Unavailable" in value:
                continue
            item = _get_item_from_key(key)
            if item in seen:
                continue
            seen.add(item)
            discovery.append({"item": item, "params": {}, "metrics": ["temperature"]})
        return {"changed": False, "msg": "discovered %d temperature sensors" % len(discovery),
                "data": {"discovery": discovery, "host_labels": {"cmk/liebert": "true"}}}
    item = params.get("item", "")
    if not _probe_liebert(ctx, host, community):
        return {"changed": False, "msg": "no Liebert device found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sensors = _fetch_liebert_sensors(ctx, host, community)
    item_data = _get_item_data(item, sensors)
    if item_data == None:
        return {"changed": False, "msg": "no such sensor: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    value, unit = item_data
    if "Unavailable" in value:
        return {"changed": False, "msg": "sensor value unavailable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    value_float = _parse_float(value)
    if value_float == None:
        return {"changed": False, "msg": "cannot convert value to float: " + value,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    celsius = _temperature_to_celsius(value_float, unit)
    levels = params.get("levels", (30, 50))
    warn_level = levels[0]
    crit_level = levels[1]
    if celsius >= crit_level:
        state = "CRIT"
    elif celsius >= warn_level:
        state = "WARN"
    else:
        state = "OK"
    msg = "%s Temperature: %f C" % (item, celsius)
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"temperature": celsius}, "details": msg}}