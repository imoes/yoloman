# ===== Starlark check module: checkmk.ups_cps_outphase =====

# Helper to parse SNMP OID response lines into float values
def _parse_snmp_value(s):
    s = s.strip()
    if s == "":
        return None
    # Remove leading "INTEGER: " or "INTEGER:" if present
    if s.startswith("INTEGER: "):
        s = s[9:]
    elif s.startswith("INTEGER:"):
        s = s[8:]
    s = s.strip()
    if s == "":
        return None
    # Guard: validate string format before parsing
    # Allow optional leading minus sign
    sign = 1
    if s.startswith("-"):
        s = s[1:]
        sign = -1
    # Split on decimal point
    parts = s.split(".", 1)
    # Check integer part is digits (or empty for ".5" case)
    int_part = parts[0]
    if int_part == "":
        int_ok = True
    else:
        int_ok = int_part.isdigit()
    # Check fractional part if present
    frac_ok = len(parts) == 1 or (len(parts) == 2 and (parts[1] == "" or parts[1].isdigit()))
    if not (int_ok and frac_ok):
        return None
    # Now safely convert
    try_val = float(s) * sign
    # Return the float value
    return try_val

# Main discovery + check function
def main(ctx, params):
    if params.get("_discover"):
        base_oid = ".1.3.6.1.4.1.3808.1.1.1.4.2"
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            base_oid
        ], mutates=False)

        if res.rc != 0:
            fail("SNMP query failed: " + res.stderr)

        # Parse output: expected lines like:
        # .1.3.6.1.4.1.3808.1.1.1.4.2.1.0 = INTEGER: 2305
        # .1.3.6.1.4.1.3808.1.1.1.4.2.2.0 = INTEGER: 500
        # .1.3.6.1.4.1.3808.1.1.1.4.2.3.0 = INTEGER: 40
        # .1.3.6.1.4.1.3808.1.1.1.4.2.4.0 = INTEGER: 205
        voltage = None
        frequency = None
        output_load = None
        current = None

        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.split(" = ")
            if len(parts) < 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            
            # Extract numeric value
            value = ""
            if value_part.startswith("INTEGER: "):
                value = value_part[9:]
            elif value_part.startswith("INTEGER:"):
                value = value_part[8:]
            else:
                continue
            
            # Map OIDs by suffix: .1, .2, .3, .4 after base
            suffix = oid_part.rsplit(".", 1)[-1] if "." in oid_part else ""
            val = _parse_snmp_value(value)
            if val != None:
                if suffix == "1":
                    voltage = val
                elif suffix == "2":
                    frequency = val
                elif suffix == "3":
                    output_load = val
                elif suffix == "4":
                    current = val

        # If we found valid data, create one item "1"
        if voltage != None and frequency != None and output_load != None and current != None:
            return {
                "changed": False,
                "msg": "discovered 1 UPS output phase",
                "data": {
                    "discovery": [
                        {
                            "item": "1",
                            "params": {},
                            "metrics": ["voltage", "frequency", "output_load", "current"]
                        }
                    ]
                }
            }
        # Otherwise, nothing to discover
        return {
            "changed": False,
            "msg": "discovered 0 UPS output phases",
            "data": {"discovery": []}
        }

    # ===== CHECK MODE =====
    item = params.get("item", "")
    if item != "1":
        return {
            "changed": False,
            "msg": "unknown item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    base_oid = ".1.3.6.1.4.1.3808.1.1.1.4.2"
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        base_oid
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    voltage = None
    frequency = None
    output_load = None
    current = None

    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split(" = ")
        if len(parts) < 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        
        # Extract numeric value
        value = ""
        if value_part.startswith("INTEGER: "):
            value = value_part[9:]
        elif value_part.startswith("INTEGER:"):
            value = value_part[8:]
        else:
            continue
        
        # Map OIDs by suffix
        suffix = oid_part.rsplit(".", 1)[-1] if "." in oid_part else ""
        val = _parse_snmp_value(value)
        if val != None:
            if suffix == "1":
                voltage = val
            elif suffix == "2":
                frequency = val
            elif suffix == "3":
                output_load = val
            elif suffix == "4":
                current = val

    # If data is missing, report UNKNOWN
    if voltage == None or frequency == None or output_load == None or current == None:
        return {
            "changed": False,
            "msg": "missing SNMP data for phase",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Convert to expected types
    voltage_val = voltage / 10.0
    frequency_val = frequency / 10.0
    output_load_val = output_load
    current_val = current / 10.0

    # Determine state based on typical thresholds (defaults provided)
    # Checkmk defaults for levels are usually empty (no levels set)
    # So always OK unless we have explicit params
    warn_voltage = None
    crit_voltage = None
    warn_current = None
    crit_current = None

    upper_voltage = params.get("levels_upper_voltage", (None, None))
    if upper_voltage[1] != None:
        warn_voltage = upper_voltage[1]
    if upper_voltage[0] != None:
        crit_voltage = upper_voltage[0]
    
    upper_current = params.get("levels_upper_current", (None, None))
    if upper_current[1] != None:
        warn_current = upper_current[1]
    if upper_current[0] != None:
        crit_current = upper_current[0]

    # Voltage check: if upper limits provided
    state = "OK"
    if crit_voltage != None and voltage_val >= crit_voltage:
        state = "CRIT"
    elif warn_voltage != None and voltage_val >= warn_voltage:
        state = "WARN"

    # Current check (output load can be considered as %, but current is the actual metric)
    if state == "OK":
        if crit_current != None and current_val >= crit_current:
            state = "CRIT"
        elif warn_current != None and current_val >= warn_current:
            state = "WARN"

    # Build message with readable values
    msg = "Voltage: %f V, Frequency: %f Hz, Load: %f%%, Current: %f A" % (
        voltage_val, frequency_val, output_load_val, current_val
    )

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "voltage": voltage_val,
                "frequency": frequency_val,
                "output_load": output_load_val,
                "current": current_val
            },
            "details": ""
        }
    }