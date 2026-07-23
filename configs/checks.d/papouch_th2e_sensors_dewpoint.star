def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = ".1.3.6.1.4.1.18248.20.1.2.1.1"

    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On",
            host,
            base_oid + ".3"
        ], mutates=False)

        if res.rc != 0:
            return {
                "changed": False,
                "msg": "discovery failed: SNMP walk of dewpoint section failed",
                "data": {"discovery": []}
            }

        dewpoint_items = []
        lines = res.stdout.splitlines()
        for line in lines:
            if line.find("=") == -1:
                continue
            parts = line.strip().split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_part, val_part = parts[0], parts[1]
            if val_part.find(": ") == -1:
                continue
            val = val_part.split(": ")[1]
            oid_parts = oid_part.strip().split(".")
            sensor_id = oid_parts[-1]
            dewpoint_items.append({
                "item": "Sensor " + sensor_id,
                "params": {},
                "metrics": ["dewpoint"]
            })

        return {
            "changed": False,
            "msg": "discovered %d dewpoint sensors" % len(dewpoint_items),
            "data": {"discovery": dewpoint_items}
        }

    item = params.get("item", "")
    if item == "":
        fail("item must be specified for dewpoint check (e.g., 'Sensor 1')")

    sensor_id = item[7:] if item.startswith("Sensor ") else item

    res = ctx.run([
        "snmpget",
        "-v2c",
        "-c", community,
        "-On",
        host,
        base_oid + ".1." + sensor_id,
        base_oid + ".2." + sensor_id,
        base_oid + ".3." + sensor_id
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP get failed for dewpoint sensor " + sensor_id,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    lines = res.stdout.splitlines()
    values = {}
    for line in lines:
        if line.find("=") == -1:
            continue
        parts = line.strip().split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part, val_part = parts[0], parts[1]
        if val_part.find(": ") == -1:
            continue
        val = val_part.split(": ")[1]
        oid_parts = oid_part.strip().split(".")
        type_idx = oid_parts[-2]
        values[type_idx] = val

    if not values.get("1") or not values.get("2"):
        return {
            "changed": False,
            "msg": "dewpoint sensor " + sensor_id + " not available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    state_map = {
        "0": (0, "OK"),
        "1": (3, "not available"),
        "2": (1, "over-flow"),
        "3": (1, "under-flow"),
        "4": (2, "error")
    }
    state_code, state_name = state_map.get(values.get("1"), (3, "unknown"))
    if state_code == 0:
        state = "OK"
    elif state_code == 1:
        state = "WARN"
    elif state_code == 2:
        state = "CRIT"
    else:
        state = "UNKNOWN"

    reading_str = values.get("2")
    if not reading_str.isdigit():
        return {
            "changed": False,
            "msg": "invalid dewpoint reading for sensor " + sensor_id,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    dewpoint = float(reading_str) / 10.0

    unit_map = {
        "0": "C",
        "1": "F",
        "2": "K",
        "3": "%"
    }
    unit = unit_map.get(values.get("3"), "C")

    msg = "Dew point: %f %s, Status: %s" % (dewpoint, unit, state_name)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"dewpoint": dewpoint},
            "details": ""
        }
    }