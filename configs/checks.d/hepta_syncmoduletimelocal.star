def main(ctx, params):
    # Read hepta section data via SNMP
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Base OIDs from the original SNMP sections (two possible trees)
    base_oid_1 = ".1.3.6.1.4.1.12527.29"
    base_oid_2 = ".1.3.6.1.4.1.12527.40"
    oids = ["1.1.0", "1.3.0", "1.4.0", "1.5.0", "1.6.0", "2.1.2.0", "3.1.0", "3.5.0"]
    
    # Try the first base OID tree first, fall back to second if needed
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid_1], mutates=False)
    output = res.stdout.strip()
    if not output:
        # Fall back to second base OID
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid_2], mutates=False)
        output = res.stdout.strip()
        if not output:
            return {
                "changed": False,
                "msg": "No SNMP data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }

    # Parse SNMP output: format is ".oid.1.2.0 = STRING: value"
    section = {}
    lines = output.splitlines()
    # Map OID suffixes to indices
    oid_map = {}
    for idx, oid_suffix in enumerate(oids):
        oid_map[oid_suffix] = idx
    
    # Extract values
    for line in lines:
        parts = line.strip().split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_full = parts[0].strip()
        value = parts[1].strip()
        # Remove quotes if present
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        
        # Extract last component of OID
        for suffix in oids:
            if oid_full.endswith(suffix):
                idx = oid_map[suffix]
                if idx == 0:
                    section["devicetype"] = value
                elif idx == 1:
                    section["serialnumber"] = value
                elif idx == 2:
                    section["firmwareversion"] = value
                elif idx == 3:
                    section["firmwaredate"] = value
                elif idx == 4:
                    section["version"] = value
                elif idx == 5:
                    section["ntpstratum"] = value
                elif idx == 6:
                    section["syncmoduletimelocal"] = value
                elif idx == 7:
                    section["syncmoduletimesyncstate"] = value
    
    # If section is empty, try alternative parsing (fallback)
    if not section:
        # Alternative approach: map by position in the tree output
        # First 8 lines correspond to the 8 OIDs in order
        lines = [l for l in lines if " = " in l]
        values = []
        for l in lines:
            parts = l.strip().split(" = ", 1)
            if len(parts) == 2:
                value = parts[1].strip()
                if value.startswith('"') and value.endswith('"'):
                    value = value[1:-1]
                values.append(value)
        if len(values) >= 8:
            section = {
                "devicetype": values[0],
                "serialnumber": values[1],
                "firmwareversion": values[2],
                "firmwaredate": values[3],
                "version": values[4],
                "ntpstratum": values[5],
                "syncmoduletimelocal": values[6],
                "syncmoduletimesyncstate": values[7],
            }
    
    # Handle discovery mode
    if params.get("_discover"):
        if section:
            return {
                "changed": False,
                "msg": "discovered 1 service",
                "data": {
                    "discovery": [
                        {
                            "item": "SyncModuleTimeLocal",
                            "params": {},
                            "metrics": [],
                        }
                    ]
                },
            }
        else:
            return {
                "changed": False,
                "msg": "discovered 0 services",
                "data": {"discovery": []},
            }

    # Check mode for SyncModuleTimeLocal
    if section and "syncmoduletimelocal" in section:
        module_time = section["syncmoduletimelocal"]
        return {
            "changed": False,
            "msg": "Module Time: " + module_time,
            "data": {
                "state": "OK",
                "metrics": {},
                "details": "",
            },
        }
    else:
        return {
            "changed": False,
            "msg": "No hepta section data available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }