def main(ctx, params):
    # Constants for SNMP OIDs (from the Checkmk source)
    FAN_SPEED_BASE = ".1.3.6.1.4.1.20858.10.31.1.1.1"
    FAN_STATUS_BASE = ".1.3.6.1.4.1.20858.10.33.1.4.1"

    # Helper to parse snmpwalk output: "OID = INTEGER: value" -> (end_part, value)
    def parse_snmp_line(line):
        parts = line.strip().split(" = INTEGER: ")
        if len(parts) != 2:
            return None, None
        oid_part = parts[0].strip()
        # Extract end part after base OID
        value = parts[1].strip()
        # Get last octet of OID (e.g., from ".1.3.6.1.4.1.20858.10.31.1.1.1.2" get "2")
        oid_end = oid_part.rsplit(".", 1)[-1]
        return oid_end, value

    # Discovery mode
    if params.get("_discover"):
        # Fetch fan speeds
        res_speed = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                             "-On", params.get("host", "localhost"), FAN_SPEED_BASE],
                            mutates=False)
        if res_speed.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed for fan speeds",
                    "data": {"discovery": []}}

        fan_items = []
        for line in res_speed.stdout.splitlines():
            if not line.strip():
                continue
            nr, _ = parse_snmp_line(line)
            if nr != None:
                fan_items.append({"item": nr, "params": {}, "metrics": []})

        return {"changed": False, "msg": "discovered %d fans" % len(fan_items),
                "data": {"discovery": fan_items}}

    # Check mode
    item = params.get("item", "")
    if item == None:
        item = ""

    # Fetch fan speeds and statuses in one go (two separate walks)
    res_speed = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                         "-On", params.get("host", "localhost"), FAN_SPEED_BASE],
                        mutates=False)
    if res_speed.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed for fan %s (speed)" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res_status = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                          "-On", params.get("host", "localhost"), FAN_STATUS_BASE],
                         mutates=False)
    if res_status.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed for fan %s (status)" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Build fan list from speed section
    fans = []
    for line in res_speed.stdout.splitlines():
        if not line.strip():
            continue
        nr, speed = parse_snmp_line(line)
        if nr != None:
            fans.append((nr, speed))

    # Build status map
    status_map = {}
    for line in res_status.stdout.splitlines():
        if not line.strip():
            continue
        nr, status = parse_snmp_line(line)
        if nr != None:
            status_map[nr] = status

    # Find matching fan item
    for nr, speed in fans:
        if nr == item:
            fan_status = status_map.get(nr, "0")
            if fan_status == "1":
                return {"changed": False, "msg": "%s RPM" % speed,
                        "data": {"state": "OK", "metrics": {"rpm": int(speed)}, "details": ""}}
            if fan_status == "3":
                return {"changed": False, "msg": "%s RPM, running over threshold (!)" % speed,
                        "data": {"state": "WARN", "metrics": {"rpm": int(speed)}, "details": ""}}
            if fan_status == "2":
                return {"changed": False, "msg": "%s RPM, running under threshold (!)" % speed,
                        "data": {"state": "WARN", "metrics": {"rpm": int(speed)}, "details": ""}}
            if fan_status == "0":
                return {"changed": False, "msg": "%s RPM, unknown fan status (!)" % speed,
                        "data": {"state": "UNKNOWN", "metrics": {"rpm": int(speed)}, "details": ""}}
            if fan_status == "4":
                return {"changed": False, "msg": "FAN Failure (!!)",
                        "data": {"state": "CRIT", "metrics": {"rpm": int(speed)}, "details": ""}}

    # Fan not found
    return {"changed": False, "msg": "Fan %s not found in snmp output" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
