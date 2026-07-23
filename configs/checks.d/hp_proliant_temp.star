hp_proliant_locale = {
    1: "other",
    2: "unknown",
    3: "system",
    4: "systemBoard",
    5: "ioBoard",
    6: "cpu",
    7: "memory",
    8: "storage",
    9: "removableMedia",
    10: "powerSupply",
    11: "ambient",
    12: "chassis",
    13: "bridgeCard",
    14: "managementBoard",
    15: "backplane",
    16: "networkSlot",
    17: "bladeSlot",
    18: "virtual",
}

hp_proliant_status_map = {
    1: "unknown",
    2: "ok",
    3: "degraded",
    4: "failed",
    5: "disabled",
}

# Checkmk STATUS_MAP (State enum mapping)
status_to_state = {
    "unknown": 3,  # UNKNOWN
    "other": 3,    # UNKNOWN
    "ok": 0,       # OK
    "degraded": 2, # CRIT
    "failed": 2,   # CRIT
    "disabled": 1, # WARN
}


def _format_name(name, locale_code):
    # locale_code is a string from SNMP
    loc = hp_proliant_locale.get(int(locale_code), "unknown")
    return name + " (" + loc + ")"


def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.232.6.2.6.8.1"
        ], mutates=False)
        
        lines = res.stdout.splitlines()
        items = []
        # Parse OID lines: ".1.3.6.1.4.1.232.6.2.6.8.1.x = STRING: \"value\""
        # Expected 5 OIDs per row: name(2), location(3), temp(4), threshold(5), status(6)
        # Group them as 5-tuples per row
        entries = []
        current = []
        for line in lines:
            # Extract OID value after '='
            if "=" in line:
                parts = line.split("=", 1)
                if len(parts) == 2:
                    oid_val = parts[1].strip()
                    # Strip quotes if present
                    if oid_val.startswith('"') and oid_val.endswith('"'):
                        oid_val = oid_val[1:-1]
                    current.append(oid_val)
                    if len(current) == 5:
                        entries.append(current)
                        current = []
        
        # Discover entries with status != 1 (not "other")
        for e in entries:
            if len(e) >= 5:
                name, locale_code, temp_val, threshold, status = e[0], e[1], e[2], e[3], e[4]
                if status != "1":  # status 1 = "other" -> skip
                    item = _format_name(name, locale_code)
                    items.append({
                        "item": item,
                        "params": {},
                        "metrics": ["temp"]
                    })
        
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(items),
            "data": {"discovery": items}
        }
    
    # Check mode
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.232.6.2.6.8.1"
    ], mutates=False)
    
    lines = res.stdout.splitlines()
    
    # Parse rows as before
    entries = []
    current = []
    for line in lines:
        if "=" in line:
            parts = line.split("=", 1)
            if len(parts) == 2:
                oid_val = parts[1].strip()
                if oid_val.startswith('"') and oid_val.endswith('"'):
                    oid_val = oid_val[1:-1]
                current.append(oid_val)
                if len(current) == 5:
                    entries.append(current)
                    current = []
    
    # Find matching item
    for e in entries:
        if len(e) >= 5:
            name, locale_code, temp_val, threshold, status = e[0], e[1], e[2], e[3], e[4]
            check_item = _format_name(name, locale_code)
            if check_item != item:
                continue
            
            # Parse temperature value
            value = float(temp_val) if temp_val.lstrip('-').replace('.', '', 1).isdigit() else 0.0
            
            # Threshold handling
            if threshold == "-99" or threshold == "0":
                dev_levels = None
            else:
                threshold_f = float(threshold) if threshold.replace('.', '', 1).lstrip('-').isdigit() else None
                if threshold_f != None:
                    dev_levels = (threshold_f, threshold_f)
                else:
                    dev_levels = None
            
            # SNMP status to Checkmk state
            snmp_status = hp_proliant_status_map.get(int(status), "unknown")
            dev_status = status_to_state.get(snmp_status, 3)  # default UNKNOWN
            
            # Determine result state and message using thresholds from params
            warn = params.get("levels", (None, None))
            crit = params.get("levels_lower", (None, None))
            # Checkmk temperature check uses warn and crit as (warn, crit) tuple
            # But in this simplified implementation, we use default Checkmk levels:
            warn_val = params.get("levels", (70.0, 80.0))
            crit_val = params.get("levels", (75.0, 90.0))
            
            # Simplified temperature logic: check against warn/crit thresholds
            # If dev_levels present, override default thresholds
            if dev_levels != None:
                warn_val = dev_levels[0]
                crit_val = dev_levels[1]
            
            # Check levels (upper bounds: warn, crit thresholds)
            state = "OK"
            if value >= crit_val:
                state = "CRIT"
            elif value >= warn_val:
                state = "WARN"
            
            # If dev_status indicates non-OK, use worst between dev_status and value-based state
            if dev_status == 2:  # CRIT
                state = "CRIT"
            elif dev_status == 1 and state != "CRIT":  # WARN
                state = "WARN"
            elif dev_status == 3 and state == "OK":  # UNKNOWN
                state = "UNKNOWN"
            
            details = "Unit: " + snmp_status
            msg = "Temperature: %f °C" % value
            if details:
                msg += ", " + details
            
            return {
                "changed": False,
                "msg": msg,
                "data": {
                    "state": state,
                    "metrics": {"temp": value},
                    "details": details
                }
            }
    
    # Item not found
    return {
        "changed": False,
        "msg": "temperature item not found: " + item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
    }