def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        base_oid = ".1.3.6.1.4.1.35491.30"
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)

        items = {}
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_part, val_part = parts
            oid_tokens = oid_part.split(".")
            if len(oid_tokens) >= 13:
                sensor_num_str = oid_tokens[11]
                sensor_num = int(sensor_num_str) if sensor_num_str.isdigit() else -1
                if sensor_num >= 0 and oid_tokens[-1] == "5":
                    sensor_name = val_part.strip().strip('"')
                    item_name = str(sensor_num) + " " + sensor_name
                    items[sensor_num] = item_name

        out = []
        for sensor_num in sorted(items.keys()):
            item_name = items[sensor_num]
            out.append({"item": item_name, "params": {}, "metrics": []})

        return {
            "changed": False,
            "msg": "discovered %d humidity sensors" % len(out),
            "data": {"discovery": out},
        }

    item = params.get("item", "")
    if not item:
        fail("item is required for check mode")

    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = ".1.3.6.1.4.1.35491.30"

    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed for item %s: %s" % (item, res.stderr),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    parts = item.split(" ", 1)
    if len(parts) < 2:
        return {
            "changed": False,
            "msg": "invalid item format: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    num_str = parts[0]
    sensor_num_expected = int(num_str) if num_str.isdigit() else -1

    sensor_data = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts_line = line.strip().split(" = ")
        if len(parts_line) != 2:
            continue
        oid_part, val_part = parts_line
        oid_tokens = oid_part.split(".")
        if len(oid_tokens) < 13:
            continue
        num_str_token = oid_tokens[11]
        if not num_str_token.isdigit():
            continue
        n = int(num_str_token)
        if n != sensor_num_expected:
            continue

        suffix = oid_tokens[-1]
        val = val_part.strip().strip('"')
        if suffix == "2":
            sensor_data["value"] = float(val) if val.replace(".", "", 1).isdigit() else None
        elif suffix == "6":
            sensor_data["alarm"] = int(val) if val.lstrip("-").isdigit() else -1
        elif suffix == "7":
            try_val = val if val.lstrip("-").isdigit() else ""
            sensor_data["crit_low"] = int(try_val) / 1000.0 if try_val else None
        elif suffix == "8":
            try_val = val if val.lstrip("-").isdigit() else ""
            sensor_data["warn_low"] = int(try_val) / 1000.0 if try_val else None
        elif suffix == "9":
            try_val = val if val.lstrip("-").isdigit() else ""
            sensor_data["warn_high"] = int(try_val) / 1000.0 if try_val else None
        elif suffix == "10":
            try_val = val if val.lstrip("-").isdigit() else ""
            sensor_data["crit_high"] = int(try_val) / 1000.0 if try_val else None

    if not sensor_data or sensor_data.get("value") == None:
        return {
            "changed": False,
            "msg": "Sensor not found in SNMP output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    value = sensor_data["value"]
    warn_high = params.get("levels", (None, None))
    warn_low = params.get("levels_lower", (None, None))
    if warn_high == None:
        warn_high = (sensor_data.get("warn_high"), sensor_data.get("crit_high"))
    else:
        warn_high = (warn_high[0], warn_high[1])
    if warn_low == None:
        warn_low = (sensor_data.get("warn_low"), sensor_data.get("crit_low"))
    else:
        warn_low = (warn_low[0], warn_low[1])

    warn_high = (warn_high[0] if warn_high[0] != None else None, warn_high[1] if warn_high[1] != None else None)
    warn_low = (warn_low[0] if warn_low[0] != None else None, warn_low[1] if warn_low[1] != None else None)

    state = "OK"
    details_parts = ["Humidity: %f%%" % value]
    metrics = {"humidity": value}

    if warn_high[1] != None and value >= warn_high[1]:
        state = "CRIT"
        details_parts.append("(warn at %f%%, crit at %f%%)" % (warn_high[0] if warn_high[0] != None else 0, warn_high[1]))
    elif warn_high[0] != None and value >= warn_high[0]:
        state = "WARN"
        details_parts.append("(warn at %f%%, crit at %f%%)" % (warn_high[0], warn_high[1] if warn_high[1] != None else 0))

    if warn_low[1] != None and value <= warn_low[1]:
        state = "CRIT"
        details_parts.append("(warn low at %f%%, crit low at %f%%)" % (warn_low[0] if warn_low[0] != None else 0, warn_low[1]))
    elif warn_low[0] != None and value <= warn_low[0]:
        state = "WARN"
        details_parts.append("(warn low at %f%%, crit low at %f%%)" % (warn_low[0], warn_low[1] if warn_low[1] != None else 0))

    alarm = sensor_data.get("alarm")
    if alarm == 99:
        state = "UNKNOWN"
        details_parts = ["Smoke Sensor is not ready or bus element removed"]

    return {
        "changed": False,
        "msg": ", ".join(details_parts),
        "data": {"state": state, "metrics": metrics, "details": ""},
    }