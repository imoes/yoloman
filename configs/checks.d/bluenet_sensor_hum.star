# Module-level constants
HUM_DEFAULT_LEVELS = (60, 65)  # (warn_high, crit_high)
HUM_DEFAULT_LEVELS_LOWER = (40, 35)  # (warn_low, crit_low)

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.21695.1.10.7.3.1"
        ], mutates=False)
        if res.rc != 0 or res.stdout == "":
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}

        # Parse snmpwalk output: OID = TYPE: value
        # Expected OIDs: .1.3.6.1.4.1.21695.1.10.7.3.1.1 (sensor_id), .2 (sensor_type), .4 (temp), .5 (hum)
        # Group by row index
        entries = []
        rows = {}
        for line in res.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_full, value_part = parts
            # Extract base OID and index
            if not oid_full.startswith(".1.3.6.1.4.1.21695.1.10.7.3.1."):
                continue
            suffix = oid_full.split(".", 9)[-1]
            if len(suffix.split(".")) < 2:
                continue
            idx_str = suffix.split(".")[0]
            key = suffix.split(".", 1)[1]  # 1,2,4,5
            if idx_str not in rows:
                rows[idx_str] = {}
            rows[idx_str][key] = value_part.split(": ", 1)[-1].strip() if ": " in value_part else ""

        # Build list of humidity-capable sensors (sensor_type == "2")
        discovery_items = []
        for idx, data in rows.items():
            sensor_id = data.get("1", "")
            sensor_type = data.get("2", "")
            if sensor_type == "2" and sensor_id != "":
                item_name = "external " + sensor_id if sensor_id != "0" else "internal"
                discovery_items.append({
                    "item": item_name,
                    "params": {"levels": HUM_DEFAULT_LEVELS, "levels_lower": HUM_DEFAULT_LEVELS_LOWER},
                    "metrics": ["humidity"]
                })

        return {
            "changed": False,
            "msg": "discovered %d humidity sensors" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }

    # Check mode
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.21695.1.10.7.3.1"
    ], mutates=False)
    if res.rc != 0 or res.stdout == "":
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse snmpwalk output: OID = TYPE: value
    rows = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_full, value_part = parts
        if not oid_full.startswith(".1.3.6.1.4.1.21695.1.10.7.3.1."):
            continue
        suffix = oid_full.split(".", 9)[-1]
        if len(suffix.split(".")) < 2:
            continue
        idx_str = suffix.split(".")[0]
        key = suffix.split(".", 1)[1]  # 1,2,4,5
        if idx_str not in rows:
            rows[idx_str] = {}
        rows[idx_str][key] = value_part.split(": ", 1)[-1].strip() if ": " in value_part else ""

    # Find matching humidity sensor
    humidity = None
    for idx, data in rows.items():
        sensor_id = data.get("1", "")
        sensor_type = data.get("2", "")
        sensor_hum = data.get("5", "")
        item_name = "external " + sensor_id if sensor_id != "0" else "internal"
        if item_name == item and sensor_type == "2" and sensor_hum != "":
            # Guard instead of try/except - check if string is numeric
            hum_str = sensor_hum.strip()
            if hum_str.isdigit() or (hum_str.startswith("-") and hum_str[1:].isdigit()):
                humidity = float(hum_str) / 10.0
            break

    if humidity == None:
        return {
            "changed": False,
            "msg": "humidity sensor not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Extract thresholds from params
    levels = params.get("levels", HUM_DEFAULT_LEVELS)
    levels_lower = params.get("levels_lower", HUM_DEFAULT_LEVELS_LOWER)
    warn_high = levels[0] if len(levels) > 0 else 60.0
    crit_high = levels[1] if len(levels) > 1 else 65.0
    warn_low = levels_lower[0] if len(levels_lower) > 0 else 40.0
    crit_low = levels_lower[1] if len(levels_lower) > 1 else 35.0

    # Determine state
    state = "OK"
    if humidity >= crit_high:
        state = "CRIT"
    elif humidity >= warn_high:
        state = "WARN"
    elif humidity <= crit_low:
        state = "CRIT"
    elif humidity <= warn_low:
        state = "WARN"

    msg = "Humidity: %f%%" % humidity

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"humidity": humidity},
            "details": ""
        }
    }
