def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.20246.2.3.1.1.1.2.3"
        ], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP walk failed",
                "data": {"discovery": []}
            }

        lines = res.stdout.splitlines()
        if len(lines) < 8:
            return {
                "changed": False,
                "msg": "incomplete SNMP data",
                "data": {"discovery": []}
            }

        values = []
        for line in lines:
            if not line:
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            val_part = parts[1]
            if ":" in val_part:
                val = val_part.split(":", 1)[1].strip()
                values.append(val)

        if len(values) < 8:
            return {
                "changed": False,
                "msg": "missing fields",
                "data": {"discovery": []}
            }

        load_current = values[1]
        rectifier_current = values[6]

        items = []
        if load_current != "2147483647":
            items.append({
                "item": "Battery",
                "params": {},
                "metrics": ["current"]
            })
        if rectifier_current != "2147483647":
            items.append({
                "item": "Rectifier",
                "params": {},
                "metrics": ["current"]
            })

        return {
            "changed": False,
            "msg": "discovered %d direct current items" % len(items),
            "data": {"discovery": items}
        }

    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community,
        "-On", host,
        ".1.3.6.1.4.1.20246.2.3.1.1.1.2.3"
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    lines = res.stdout.splitlines()
    if len(lines) < 8:
        return {
            "changed": False,
            "msg": "incomplete SNMP data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    values = []
    for line in lines:
        if not line:
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        val_part = parts[1]
        if ":" in val_part:
            val = val_part.split(":", 1)[1].strip()
            values.append(val)

    if len(values) < 7:
        return {
            "changed": False,
            "msg": "missing fields",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    load_current = values[1]
    rectifier_current = values[6]
    battery_temp = values[3]

    current_map = {}
    if load_current != "2147483647":
        if battery_temp.isdigit():
            val = int(battery_temp) * 0.1
            current_map["Battery"] = val
    if rectifier_current != "2147483647":
        if battery_temp.isdigit():
            val = int(battery_temp) * 0.1
            current_map["Rectifier"] = val

    if item not in current_map:
        return {
            "changed": False,
            "msg": "item not found: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    current_val = current_map[item]
    warn_val = 10.0
    crit_val = 15.0
    levels = params.get("levels")
    if levels != None:
        if type(levels) == "list":
            if len(levels) >= 2:
                if type(levels[0]) == "int" or type(levels[0]) == "float":
                    warn_val = float(levels[0])
                if type(levels[1]) == "int" or type(levels[1]) == "float":
                    crit_val = float(levels[1])

    state = "OK"
    if current_val >= crit_val:
        state = "CRIT"
    elif current_val >= warn_val:
        state = "WARN"

    return {
        "changed": False,
        "msg": "Current: %f A, %s" % (current_val, state),
        "data": {
            "state": state,
            "metrics": {"current": current_val},
            "details": ""
        }
    }