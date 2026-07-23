def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.1588.2.1.1.1.1.22.1"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed: " + res.stderr,
                    "data": {"discovery": []}}
        
        # Parse SNMP output: "<OID> = <TYPE>: <value>"
        lines = res.stdout.splitlines()
        section = []
        for line in lines:
            if not line.strip():
                continue
            parts = line.split(" = ")
            if len(parts) != 2:
                continue
            value_part = parts[1]
            # Extract value after type (e.g., "INTEGER: 1" -> "1")
            if ":" in value_part:
                value = value_part.split(":", 1)[1].strip()
            else:
                value = value_part.strip()
            
            # The OID ends with .3, .4, or .5 mapping to presence, state, name
            # Extract base OID index (last number before .3/.4/.5)
            oid_base = parts[0].strip()
            last_dot = oid_base.rfind(".")
            if last_dot == -1:
                continue
            index_str = oid_base[last_dot+1:]
            
            # Group consecutive OIDs with same index (3 values per entry)
            if oid_base.endswith(".3"):
                presence = value
            elif oid_base.endswith(".4"):
                state = value
            elif oid_base.endswith(".5"):
                name = value
                # We have all three values now
                section.append([presence, state, name])
        
        out = []
        for presence, state, name in section:
            name = name.lstrip()
            # Only power supplies
            if name.startswith("Power") and presence != "6":
                sensor_id = name.split("#")[-1]
                out.append({"item": sensor_id, "params": {},
                           "metrics": []})
        
        return {"changed": False, "msg": "discovered %d power supplies" % len(out),
                "data": {"discovery": out}}
    
    # Check mode
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.1588.2.1.1.1.1.22.1"
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "snmpwalk failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    lines = res.stdout.splitlines()
    # Build section from SNMP output
    section = []
    current = [None, None, None]
    for line in lines:
        if not line.strip():
            continue
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        value_part = parts[1]
        if ":" in value_part:
            value = value_part.split(":", 1)[1].strip()
        else:
            value = value_part.strip()
        
        oid_base = parts[0].strip()
        last_dot = oid_base.rfind(".")
        if last_dot == -1:
            continue
        index_str = oid_base[last_dot+1:]
        
        if oid_base.endswith(".3"):
            current[0] = value
        elif oid_base.endswith(".4"):
            current[1] = value
        elif oid_base.endswith(".5"):
            current[2] = value
            if None not in current:
                section.append(current)
            current = [None, None, None]
    
    # Find the requested item
    found = False
    for snmp_item, name, value in section:
        if not snmp_item or not name or not value:
            continue
        name = name.lstrip()
        if name.startswith("Power") and snmp_item != "6":
            sensor_id = name.split("#")[-1]
            if item == sensor_id:
                found = True
                val = int(value) if value.isdigit() else 0
                if val != 1:
                    return {"changed": False, "msg": "Error on supply " + name,
                            "data": {"state": "CRIT", "metrics": {}, "details": ""}}
                return {"changed": False, "msg": "No problems found",
                        "data": {"state": "OK", "metrics": {}, "details": ""}}
    
    if not found:
        return {"changed": False, "msg": "Supply not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
