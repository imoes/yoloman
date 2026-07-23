def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.20246.2.3.1.1.1.2.3"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed: " + res.stderr,
                    "data": {"discovery": []}}

        lines = res.stdout.splitlines()
        if len(lines) < 8:
            return {"changed": False, "msg": "SNMP response too short",
                    "data": {"discovery": []}}

        values = []
        for line in lines:
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            val_str = parts[1].strip()
            if ":" in val_str:
                val_str = val_str.split(":", 1)[1].strip()
            values.append(val_str)

        if len(values) < 8:
            return {"changed": False, "msg": "Could not parse 8 required fields",
                    "data": {"discovery": []}}

        battery_temp = values[3]
        temp_items = []
        if battery_temp != "2147483647":
            temp_items.append({
                "item": "Battery",
                "params": {},
                "metrics": ["temperature"]
            })

        return {
            "changed": False,
            "msg": "discovered %d temperature items" % len(temp_items),
            "data": {"discovery": temp_items}
        }

    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.20246.2.3.1.1.1.2.3"
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = res.stdout.splitlines()
    if len(lines) < 8:
        return {"changed": False, "msg": "SNMP response too short",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    values = []
    for line in lines:
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        val_str = parts[1].strip()
        if ":" in val_str:
            val_str = val_str.split(":", 1)[1].strip()
        values.append(val_str)

    if len(values) < 8:
        return {"changed": False, "msg": "Could not parse 8 required fields",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    battery_temp_str = values[3]

    if item != "Battery":
        return {"changed": False, "msg": "item not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if battery_temp_str == "2147483647":
        return {"changed": False, "msg": "no battery temperature data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    battery_temp = float(int(battery_temp_str)) * 0.1 if battery_temp_str.isdigit() else -999.0
    if battery_temp_str.isdigit() == False:
        return {"changed": False, "msg": "invalid battery temperature value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    warn_upper = params.get("levels_upper")
    crit_upper = params.get("levels_lower")
    warn_u = 25.0 if warn_upper == None else warn_upper
    crit_u = 35.0 if crit_upper == None else crit_upper

    state = "OK"
    if battery_temp >= crit_u:
        state = "CRIT"
    elif battery_temp >= warn_u:
        state = "WARN"

    return {
        "changed": False,
        "msg": "Temperature: %f C" % battery_temp,
        "data": {
            "state": state,
            "metrics": {"temperature": battery_temp},
            "details": ""
        }
    }