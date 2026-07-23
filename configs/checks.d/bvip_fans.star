def main(ctx, params):
    # Constants for SNMP OIDs
    BASE_OID = ".1.3.6.1.4.1.3967.1.1.8.1"
    OID_END = BASE_OID + ".0"
    OID_RPM = BASE_OID + ".1.0"

    # Helper: discover mode
    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                      "-On", params.get("host", "localhost"), BASE_OID], mutates=False)
        items = []
        # Parse snmpwalk output: "OID = STRING: value" or "OID = INTEGER: value"
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ", 1)
            if len(parts) < 2:
                continue
            oid_part, value_part = parts
            # Only process items (end OID) and their RPM
            # Format: .1.3.6.1.4.1.3967.1.1.8.1.<index> = INTEGER: <value>
            # The first part is the item name (index), second is RPM
            if oid_part.startswith(BASE_OID + ".") and not oid_part == BASE_OID + ".1":
                # Extract index (item name) from OID
                index = oid_part[len(BASE_OID + "."):]
                # Parse value (integer)
                if value_part.strip().startswith("INTEGER: "):
                    value_str = value_part.strip().split(": ", 1)[1]
                    if value_str.isdigit():
                        rpm = int(value_str)
                        if rpm != 0:
                            # Compute default lower thresholds: (90% rpm, 80% rpm)
                            warn_lower = rpm * 0.9
                            crit_lower = rpm * 0.8
                            items.append({
                                "item": index,
                                "params": {"lower": [warn_lower, crit_lower]},
                                "metrics": ["rpm"]
                            })
        return {
            "changed": False,
            "msg": "discovered %d fans" % len(items),
            "data": {"discovery": items}
        }

    # Check mode: single item
    item = params.get("item", "")
    warn_lower, crit_lower = params.get("lower", [80.0, 70.0])

    # Query only the specific fan's RPM
    # snmpget -v2c -c <community> <host> <oid>
    fan_oid = BASE_OID + "." + item
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                  "-On", params.get("host", "localhost"), fan_oid], mutates=False)

    if not res.stdout.strip():
        return {
            "changed": False,
            "msg": "no data for fan %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse snmpget output: ".1.3.6.1.4.1.3967.1.1.8.1.<index> = INTEGER: <value>"
    line = res.stdout.strip()
    parts = line.split(" = ", 1)
    if len(parts) < 2:
        return {
            "changed": False,
            "msg": "unexpected output format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    value_part = parts[1].strip()
    if not value_part.startswith("INTEGER: "):
        return {
            "changed": False,
            "msg": "value is not an integer",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    value_str = value_part.split(": ", 1)[1]
    if not value_str.isdigit():
        return {
            "changed": False,
            "msg": "failed to parse RPM value",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    rpm = int(value_str)

    # Determine state based on lower thresholds (WARN if <= warn_lower, CRIT if <= crit_lower)
    # Checkmk's check_fan uses lower thresholds
    state = "OK"
    if rpm <= crit_lower:
        state = "CRIT"
    elif rpm <= warn_lower:
        state = "WARN"

    return {
        "changed": False,
        "msg": "%s: %d RPM" % (item, rpm),
        "data": {"state": state, "metrics": {"rpm": rpm}, "details": ""}
    }
