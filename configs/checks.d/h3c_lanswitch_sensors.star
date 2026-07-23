# Top-level constants
OID_BASE_FAN = ".1.3.6.1.4.1.43.45.1.2.23.1.9.1.1.1"
OID_BASE_POWER = ".1.3.6.1.4.1.43.45.1.2.23.1.9.1.2.1"
OID_STATUS = "2"
OID_END = ""

def _genitem(device_class, id_str):
    id_val = int(id_str)
    unitid = id_val // 65536
    num = id_val % 65536
    return "Unit %d %s %d" % (unitid, device_class, num)

def _parse_snmp_table(lines):
    # Parse snmpwalk output: "<OID> = STRING: <value>"
    result = []
    for line in lines:
        if not line.strip():
            continue
        parts = line.split(" = STRING: ", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value = parts[1].strip()
        # Extract the end part after the base OID
        if OID_END == "":
            # For OIDEnd(), we take the last component of the OID
            # Example: ".1.3.6.1.4.1.43.45.1.2.23.1.9.1.1.1.1.23" -> "1.23" becomes "1.23"
            # But Checkmk uses OIDEnd() to get the trailing instance identifier
            # Here we extract the last numeric segment
            segments = oid_part.split(".")
            item_id = ".".join(segments[-2:])  # Last two segments
        else:
            item_id = oid_part
        result.append((item_id, value))
    return result

def _walk_snmp(ctx, base_oid, community, host):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
    if res.rc != 0:
        return []
    return res.stdout.splitlines()

def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")

        # Fetch fan section
        fan_lines = _walk_snmp(ctx, OID_BASE_FAN, community, host)
        # Fetch power supply section
        power_lines = _walk_snmp(ctx, OID_BASE_POWER, community, host)

        # Parse both sections
        section = {}
        for device_class, lines in [("Fan", fan_lines), ("PowerSupply", power_lines)]:
            parsed = _parse_snmp_table(lines)
            for item_id, status in parsed:
                item = _genitem(device_class, item_id)
                section[item] = status

        # Discovery: yield services where status is "1" (active) or "2" (deactive)
        discovered = []
        for item, status in section.items():
            if status in ["1", "2"]:
                discovered.append({
                    "item": item,
                    "params": {},
                    "metrics": []
                })

        return {
            "changed": False,
            "msg": "discovered %d sensors" % len(discovered),
            "data": {"discovery": discovered}
        }

    # Check mode: single item
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Gather both sections again for the single check
    fan_lines = _walk_snmp(ctx, OID_BASE_FAN, community, host)
    power_lines = _walk_snmp(ctx, OID_BASE_POWER, community, host)

    section = {}
    for device_class, lines in [("Fan", fan_lines), ("PowerSupply", power_lines)]:
        parsed = _parse_snmp_table(lines)
        for item_id, status in parsed:
            full_item = _genitem(device_class, item_id)
            section[full_item] = status

    # Find the status for the requested item
    status = section.get(item)
    if status == None:
        return {
            "changed": False,
            "msg": "Sensor %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    if status == "2":
        state = "CRIT"
        summary = "Sensor %s status is %s" % (item, status)
    elif status == "1":
        state = "OK"
        summary = "Sensor %s status is %s" % (item, status)
    else:
        state = "WARN"
        summary = "Sensor %s status is %s" % (item, status)

    return {
        "changed": False,
        "msg": summary,
        "data": {"state": state, "metrics": {}, "details": ""}
    }