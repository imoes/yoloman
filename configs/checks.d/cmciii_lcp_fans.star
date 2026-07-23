# ===== Starlark check module: cmk.cmciii_lcp_fans =====

# SNMP OIDs for CMCIII LCP fans section (base + offset)
# Base: .1.3.6.1.4.1.2606.7.4.2.2.1.10.2
# OIDs 34..57 -> offsets 33..56 (1-indexed)
_FAN_BASE_OID = ".1.3.6.1.4.1.2606.7.4.2.2.1.10.2"
_FAN_OID_OFFSETS = [33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56]

def _snmp_walk(ctx, community, host):
    """Walk the fan section and return parsed values as list of strings."""
    values = []
    for offset in _FAN_OID_OFFSETS:
        oid = _FAN_BASE_OID + "." + str(offset)
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, oid], mutates=False)
        # snmpget output: "<oid> = STRING: <value>" or "<oid> = INTEGER: <value>"
        line = res.stdout.strip()
        # Parse value after last colon+space
        idx = line.rfind(": ")
        if idx != -1:
            value = line[idx+2:].strip('"')
            values.append(value)
        else:
            values.append("")
    return values

def _parse_snmp_values(raw_values):
    """Parse raw snmp values into section format expected by check."""
    # The first value (index 0) is the global low warning limit (as string like "1200 RPM")
    # Remaining are groups of 3: [name, value, status] per fan
    # We need to reconstruct the StringTable: [ [raw0, raw1, raw2, ...] ]
    return [raw_values]

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Discovery mode
    if params.get("_discover"):
        raw_values = _snmp_walk(ctx, community, host)
        if not raw_values or len(raw_values) < 2:
            return {"changed": False, "msg": "discovered 0 fans",
                    "data": {"discovery": []}}
        
        # First element is the low warning limit, skip it for fan parsing
        section_data = raw_values[1:]
        # Group into chunks of 3: name, value, status
        parts = []
        for i in range(0, len(section_data), 3):
            chunk = section_data[i:i+3]
            if len(chunk) >= 3:
                parts.append(chunk)
        
        inventory = []
        for i, (name, value, status) in enumerate(parts):
            if status != "off" and "FAN" in name.upper():
                inventory.append({
                    "item": str(i + 1),
                    "params": {},  # No parameters needed beyond item
                    "metrics": ["rpm"]
                })
        
        return {"changed": False, "msg": "discovered %d fans" % len(inventory),
                "data": {"discovery": inventory}}
    
    # Check mode
    item = params.get("item", "")
    raw_values = _snmp_walk(ctx, community, host)
    if not raw_values or len(raw_values) < 2:
        return {"changed": False, "msg": "no data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse low warning limit from first value (index 0)
    low_value_str = raw_values[0]
    low_rpm_str = low_value_str.split(" ", 1)[0] if " " in low_value_str else low_value_str
    lowlevel = int(low_rpm_str) if low_rpm_str.isdigit() else 0
    
    section_data = raw_values[1:]
    parts = []
    for i in range(0, len(section_data), 3):
        chunk = section_data[i:i+3]
        if len(chunk) >= 3:
            parts.append(chunk)
    
    # Find the requested item
    found = False
    for i, (name, value, status) in enumerate(parts):
        if str(i + 1) == item:
            found = True
            # Extract RPM value
            if " " in value:
                rpm_r, unit = value.split(" ", 1)
            else:
                rpm_r = value
                unit = ""
            rpm = int(rpm_r) if rpm_r.isdigit() else 0
            
            # Determine state
            sym = ""
            if status == "OK" and rpm >= lowlevel:
                state = "OK"
            elif status == "OK" and rpm < lowlevel:
                state = "WARN"
                sym = "(!)"
            else:
                state = "CRIT"
                sym = "(!!)"
            
            # Build summary
            info_text = "%s RPM: %d%s (limit %d%s)%s, Status %s" % (
                name, rpm, unit, lowlevel, unit, sym, status
            )
            
            return {"changed": False, "msg": info_text,
                    "data": {
                        "state": state,
                        "metrics": {"rpm": rpm},
                        "details": ""
                    }}
    
    if not found:
        return {"changed": False, "msg": "fan item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
