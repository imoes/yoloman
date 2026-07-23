def main(ctx, params):
    # === Discover mode ===
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.4.1.4555.1.1.1.1.4.4.1"
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            base_oid + ".1", base_oid + ".2"
        ], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)
        
        # Parse snmpwalk output: "<oid> = STRING: <phase>" and "<oid> = INTEGER: <raw_voltage>"
        lines = res.stdout.splitlines()
        phase_map = {}
        voltage_map = {}
        
        for line in lines:
            if not line.strip():
                continue
            parts = line.strip().split(" = ", 2)
            if len(parts) < 2:
                continue
            oid_part, value_part = parts
            # Extract OID suffix
            suffix = oid_part.rsplit(".", 1)[-1]
            # Parse value: "STRING: <text>" or "INTEGER: <number>"
            if value_part.startswith("STRING: "):
                phase = value_part[8:].strip().strip('"')
                if suffix not in phase_map:
                    phase_map[suffix] = phase
            elif value_part.startswith("INTEGER: "):
                raw_str = value_part[11:].strip()
                # Guard instead of try/except
                raw_voltage = int(raw_str) if raw_str.isdigit() else 0
                voltage_map[suffix] = raw_voltage
        
        # Match phases and voltages by index suffix
        discovered = []
        for suffix in phase_map:
            if suffix in voltage_map:
                raw = voltage_map[suffix]
                if raw > 0:
                    phase = phase_map[suffix]
                    # Convert raw voltage to volts (divide by 10 as in original code)
                    voltage = float(raw) / 10.0
                    # Provide default params matching Checkmk defaults
                    discovered.append({
                        "item": phase,
                        "params": {
                            "levels_lower": (210.0, 180.0)
                        },
                        "metrics": ["out_voltage"]
                    })
        
        return {
            "changed": False,
            "msg": "discovered %d phases" % len(discovered),
            "data": {"discovery": discovered}
        }
    
    # === Check mode ===
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.4555.1.1.1.1.4.4.1"
    
    # Fetch both OIDs at once
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        base_oid + ".1", base_oid + ".2"
    ], mutates=False)
    
    if res.rc != 0:
        fail("SNMP walk failed: " + res.stderr)
    
    # Parse output for the requested item
    lines = res.stdout.splitlines()
    phase_map = {}
    voltage_map = {}
    
    for line in lines:
        if not line.strip():
            continue
        parts = line.strip().split(" = ", 2)
        if len(parts) < 2:
            continue
        oid_part, value_part = parts
        suffix = oid_part.rsplit(".", 1)[-1]
        if value_part.startswith("STRING: "):
            phase = value_part[8:].strip().strip('"')
            if suffix not in phase_map:
                phase_map[suffix] = phase
        elif value_part.startswith("INTEGER: "):
            raw_str = value_part[11:].strip()
            # Guard instead of try/except
            raw_voltage = int(raw_str) if raw_str.isdigit() else 0
            voltage_map[suffix] = raw_voltage
    
    # Find the matching phase and voltage
    voltage = None
    for suffix, phase in phase_map.items():
        if phase == item and suffix in voltage_map:
            voltage = float(voltage_map[suffix]) / 10.0
            break
    
    if voltage == None:
        return {
            "changed": False,
            "msg": "phase not found: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Extract thresholds
    levels_lower = params.get("levels_lower", (210.0, 180.0))
    warn_lower = levels_lower[0] if len(levels_lower) >= 1 else 210.0
    crit_lower = levels_lower[1] if len(levels_lower) >= 2 else 180.0
    
    # Determine state: lower thresholds (warn/crit if below)
    if voltage <= crit_lower:
        state = "CRIT"
    elif voltage <= warn_lower:
        state = "WARN"
    else:
        state = "OK"
    
    return {
        "changed": False,
        "msg": "Out voltage: %f V" % voltage,
        "data": {
            "state": state,
            "metrics": {"out_voltage": voltage},
            "details": ""
        }
    }