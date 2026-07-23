# Fan type and state enums (mapped from SNMP values)
FAN_TYPE_MAP = {
    "0": "Unknown",
    "1": "MM",
    "2": "FM",
    "3": "IM",
    "4": "PS",
    "5": "Rollup",
    "6": "Maxtype",
}

FAN_STATE_MAP = {
    "0": "Failed",
    "1": "Removed",
    "2": "Off",
    "3": "Underspeed",
    "4": "Overspeed",
    "5": "OK",
    "6": "MaxState",
}

# State mapping to Checkmk states
FAN_STATE_TO_STATE = {
    "0": "CRIT",  # Failed -> CRIT
    "1": "WARN",  # Removed -> WARN
    "2": "WARN",  # Off -> WARN
    "3": "WARN",  # Underspeed -> WARN
    "4": "WARN",  # Overspeed -> WARN
    "5": "OK",    # OK -> OK
    "6": "OK",    # MaxState -> OK
}


def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.11.2.14.11.5.1.54.2.1.1",
        ], mutates=False)
        if res.rc != 0:
            fail("snmpwalk failed: " + res.stderr)
        
        # Parse SNMP output: ".1.3.6.1.4.1.11.2.14.11.5.1.54.2.1.1.<end> = INTEGER: <value>"
        items = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ", 1)
            if len(parts) < 2:
                continue
            oid_end = parts[0].rsplit(".", 1)[-1]  # get the trailing part after last dot
            value_str = parts[1].strip()
            
            # We need to parse the section data; we'll do a second query to get all four values per fan
            # For now, collect the item IDs (tray indices)
            items.append({"item": oid_end, "params": {}, "metrics": []})
        
        # Only report discovered items if we have at least one
        if items:
            return {
                "changed": False,
                "msg": "discovered %d fans" % len(items),
                "data": {"discovery": items},
            }
        else:
            return {
                "changed": False,
                "msg": "discovered 0 fans",
                "data": {"discovery": []},
            }
    
    # Normal check mode
    item = params.get("item", "")
    # Query all required fields for this fan
    base_oid = ".1.3.6.1.4.1.11.2.14.11.5.1.54.2.1.1"
    fan_oid = base_oid + "." + item
    
    # Fetch all fields in one go
    res = ctx.run([
        "snmpget",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        fan_oid + ".2",  # hpicfFanTray
        fan_oid + ".3",  # hpicfFanType
        fan_oid + ".4",  # hpicfFanState
        fan_oid + ".6",  # hpicfFanNumFailures
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "snmpget failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Parse response: "<oid> = INTEGER: <value>"
    values = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line or " = " not in line:
            continue
        parts = line.split(" = ")
        if len(parts) < 2:
            continue
        oid_full = parts[0].strip()
        value_part = parts[1].strip()
        if not value_part.startswith("INTEGER: "):
            continue
        value = value_part[len("INTEGER: "):]
        # Extract field name from OID end
        field_oid = oid_full.rsplit(".", 1)[-1]
        if field_oid == "2":
            values["tray"] = value
        elif field_oid == "3":
            values["type"] = value
        elif field_oid == "4":
            values["state"] = value
        elif field_oid == "6":
            values["failures"] = value
    
    # If any essential fields missing, return UNKNOWN
    if "type" not in values or "state" not in values:
        return {
            "changed": False,
            "msg": "fan item %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Get state and build messages
    fan_state = values.get("state", "5")
    fan_type = values.get("type", "0")
    fan_tray = values.get("tray", "0")
    fan_failures = values.get("failures", "0")
    
    state_str = FAN_STATE_MAP.get(fan_state, "Unknown")
    state_ok = FAN_STATE_TO_STATE.get(fan_state, "OK")
    
    # Build summary messages
    summary_parts = ["Fan Status: " + state_str]
    summary_parts.append("Type: " + FAN_TYPE_MAP.get(fan_type, "Unknown"))
    summary_parts.append("Tray: " + str(fan_tray))
    if fan_failures != "0" and fan_failures.isdigit() and int(fan_failures) > 0:
        summary_parts.append("Failures: " + str(fan_failures))
    
    msg = ", ".join(summary_parts)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state_ok,
            "metrics": {},
            "details": "",
        },
    }
