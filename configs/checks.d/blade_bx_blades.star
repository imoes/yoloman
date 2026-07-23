# OID definitions for blade_bx_blades SNMP section
BLADE_BX_BASE_OID = ".1.3.6.1.4.1.7244.1.1.1.4.2.1.1"
BLADE_ID_OID = "1"
BLADE_STATUS_OID = "2"
BLADE_SERIAL_OID = "5"
BLADE_NAME_OID = "21"

# Status mapping: OID value -> (state, readable)
STATUS_CODES = {
    "1": ("UNKNOWN", "unknown"),
    "2": ("OK", "OK"),
    "3": ("UNKNOWN", "not present"),
    "4": ("CRIT", "error"),
    "5": ("CRIT", "critical"),
    "6": ("OK", "standby"),
}

def main(ctx, params):
    # DISCOVERY MODE
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        
        # Build full OIDs for this section
        base = BLADE_BX_BASE_OID
        
        # Fetch all rows by walking the base OID (we need all columns together)
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)
        
        # Parse lines: "<OID> = STRING: <value>" or "<OID> = STRING: <value>"
        lines = res.stdout.splitlines()
        section = []
        
        # Group OIDs by row (same index after base)
        # We need to map: .1.3.6.1.4.1.7244.1.1.1.4.2.1.1.1 -> id
        #                                  .1.3.6.1.4.1.7244.1.1.1.4.2.1.1.2 -> status
        #                                  .1.3.6.1.4.1.7244.1.1.1.4.2.1.1.5 -> serial
        #                                  .1.3.6.1.4.1.7244.1.1.1.4.2.1.1.21 -> name
        
        # Strategy: parse into a map of row-index -> {1: id, 2: status, 5: serial, 21: name}
        rows = {}  # idx -> dict(column -> value)
        
        for line in lines:
            if "=" not in line:
                continue
            parts = line.split("=", 1)
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            val_part = parts[1].strip()
            
            # Extract index relative to base
            if not oid_part.startswith(base + "."):
                continue
            suffix = oid_part[len(base):]
            if not suffix.startswith("."):
                continue
            idx_str = suffix[1:]  # after the dot
            
            # Parse value (SNMP returns STRING: "value" or similar)
            if ":" in val_part:
                val_type, val = val_part.split(":", 1)
                val = val.strip().strip('"')
            else:
                val = val_part.strip().strip('"')
            
            # Group by row index
            row_idx = idx_str  # since base is common prefix
            
            if row_idx not in rows:
                rows[row_idx] = {}
            rows[row_idx][int(idx_str)] = val
        
        # Build section: [id, status, serial, name]
        section = []
        for idx_str in sorted(rows.keys()):
            row = rows[idx_str]
            id_val = row.get(1, "")
            status_val = row.get(2, "")
            serial_val = row.get(5, "")
            name_val = row.get(21, "")
            section.append([id_val, status_val, serial_val, name_val])
        
        # Discovery: skip blades with status == "3" (not present)
        discovery = []
        for entry in section:
            if len(entry) < 4:
                continue
            id_ = entry[0]
            status = entry[1]
            if status != "3":  # blade present
                discovery.append({"item": id_, "params": {}, "metrics": []})
        
        return {"changed": False, "msg": "discovered %d blades" % len(discovery),
                "data": {"discovery": discovery}}
    
    # CHECK MODE
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Re-fetch same data for the specific item
    base = BLADE_BX_BASE_OID
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse into section
    lines = res.stdout.splitlines()
    section = []
    rows = {}
    
    for line in lines:
        if "=" not in line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        val_part = parts[1].strip()
        
        if not oid_part.startswith(base + "."):
            continue
        suffix = oid_part[len(base):]
        if not suffix.startswith("."):
            continue
        idx_str = suffix[1:]
        
        if ":" in val_part:
            val_type, val = val_part.split(":", 1)
            val = val.strip().strip('"')
        else:
            val = val_part.strip().strip('"')
        
        row_idx = idx_str
        
        if row_idx not in rows:
            rows[row_idx] = {}
        rows[row_idx][int(idx_str)] = val
    
    for idx_str in sorted(rows.keys()):
        row = rows[idx_str]
        id_val = row.get(1, "")
        status_val = row.get(2, "")
        serial_val = row.get(5, "")
        name_val = row.get(21, "")
        section.append([id_val, status_val, serial_val, name_val])
    
    # Find the requested item
    state = "UNKNOWN"
    state_readable = "item not found"
    name_info = ""
    
    for entry in section:
        if len(entry) < 4:
            continue
        id_, status, serial, name = entry
        if id_ == item:
            status_str = str(status)
            if status_str in STATUS_CODES:
                state, state_readable = STATUS_CODES[status_str]
            else:
                state = "UNKNOWN"
                state_readable = "unknown status (" + status_str + ")"
            
            if name:
                name_info = "[" + name + ", Serial: " + serial + "]"
            else:
                name_info = "[Serial: " + serial + "]"
            break
    
    # If item not found, state is UNKNOWN
    if state == "UNKNOWN":
        state_readable = "item not found"
    
    msg = name_info + " Status: " + state_readable
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {}, "details": ""}}
