def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.14848.2.1.2.1"
        ], mutates=False)
        out = []
        lines = res.stdout.splitlines() if res.stdout else []
        for line in lines:
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_end = parts[0].strip()
            value_part = parts[1].strip()
            colon_pos = value_part.find(":")
            if colon_pos == -1:
                continue
            value_type = value_part[:colon_pos].strip()
            value_str = value_part[colon_pos + 1:].strip()
            if value_type != "INTEGER":
                continue
            value = int(value_str) if value_str.lstrip("-").isdigit() else 0
            oid_parts = oid_end.split(".")
            if len(oid_parts) < 6:
                continue
            index = oid_parts[-5]
            sensor_type = oid_parts[-3]
            if sensor_type != "6":
                continue
            name_oid = ".1.3.6.1.4.1.14848.2.1.2.1." + index + ".2"
            name_res = ctx.run([
                "snmpget", "-v2c", "-c", community, "-On",
                host, name_oid
            ], mutates=False)
            name = ""
            if name_res.rc == 0 and name_res.stdout:
                name_line = name_res.stdout.strip()
                name_colon = name_line.find(":")
                if name_colon != -1:
                    name = name_line[name_colon + 1:].strip()
            if value == 0:
                continue
            item = index + ".6"
            out.append({
                "item": item,
                "params": {"smoke_handling": ("binary", [0, 2])},
                "metrics": ["smoke"]
            })
        return {
            "changed": False,
            "msg": "discovered %d smoke sensors" % len(out),
            "data": {"discovery": out}
        }

    item = params.get("item", "")
    smoke_handling = params.get("smoke_handling", ("binary", [0, 2]))
    if smoke_handling[0] != "binary":
        smoke_handling = ("binary", [0, 2])

    community = params.get("community", "public")
    host = params.get("host", "localhost")

    item_parts = item.split(".")
    if len(item_parts) != 2:
        return {
            "changed": False,
            "msg": "invalid item format: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    index, sensor_type = item_parts
    if sensor_type != "6":
        return {
            "changed": False,
            "msg": "sensor type mismatch: expected 6, got " + sensor_type,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    value_oid = ".1.3.6.1.4.1.14848.2.1.2.1." + index + ".5"
    value_res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host, value_oid
    ], mutates=False)
    if value_res.rc != 0 or not value_res.stdout:
        return {
            "changed": False,
            "msg": "failed to get sensor value for " + index,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    value_line = value_res.stdout.strip()
    colon_pos = value_line.find(":")
    if colon_pos == -1:
        return {
            "changed": False,
            "msg": "invalid value response: " + value_line,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    value_str = value_line[colon_pos + 1:].strip()
    value = int(value_str) if value_str.lstrip("-").isdigit() else 0

    name_oid = ".1.3.6.1.4.1.14848.2.1.2.1." + index + ".2"
    name_res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host, name_oid
    ], mutates=False)
    name = ""
    if name_res.rc == 0 and name_res.stdout:
        name_line = name_res.stdout.strip()
        name_colon = name_line.find(":")
        if name_colon != -1:
            name = name_line[name_colon + 1:].strip()

    no_smoke_state, smoke_state = smoke_handling[1]
    if value == 0:
        state = "OK" if no_smoke_state == 0 else "CRIT"
        msg = "[" + name + "] No smoke detected" if name else "No smoke detected"
    else:
        state = "CRIT" if smoke_state == 2 else "OK"
        msg = "[" + name + "] Smoke detected" if name else "Smoke detected"

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"smoke": value},
            "details": ""
        }
    }
