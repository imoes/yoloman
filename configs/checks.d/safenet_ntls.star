def main(ctx, params):
    # SNMP base configuration
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = ".1.3.6.1.4.1.12383.3.1.2"
    
    # Fetch all required SNMP values in one walk
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        base_oid, ".1.3.6.1.4.1.12383.3.1.2.1",
        ".1.3.6.1.4.1.12383.3.1.2.2", ".1.3.6.1.4.1.12383.3.1.2.3",
        ".1.3.6.1.4.1.12383.3.1.2.4", ".1.3.6.1.4.1.12383.3.1.2.5",
        ".1.3.6.1.4.1.12383.3.1.2.6"
    ], mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse SNMP output into a dict of OID -> value
    snmp_data = {}
    for line in res.stdout.splitlines():
        if "=" not in line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        # Extract numeric OID suffix after base
        if oid_part.startswith(base_oid + "."):
            suffix = oid_part[len(base_oid) + 1:]
            # Strip any leading dot from suffix
            if suffix.startswith("."):
                suffix = suffix[1:]
            snmp_data[suffix] = value_part
        # Handle scalar OIDs that end with .0
        elif oid_part.startswith(base_oid) and oid_part.endswith(".0"):
            suffix = oid_part[len(base_oid) + 1:-2]  # Remove .0
            snmp_data[suffix] = value_part
    
    # Extract values with defaults for missing OIDs
    operation_status = snmp_data.get("1", "").strip('"')
    connected_clients_str = snmp_data.get("2", "").strip('"')
    links_str = snmp_data.get("3", "").strip('"')
    successful_connections_str = snmp_data.get("4", "").strip('"')
    failed_connections_str = snmp_data.get("5", "").strip('"')
    expiration_date = snmp_data.get("6", "").strip('"')
    
    # Convert numeric fields; use 0 for invalid values
    connected_clients = int(connected_clients_str) if connected_clients_str.isdigit() else 0
    links = int(links_str) if links_str.isdigit() else 0
    successful_connections = int(successful_connections_str) if successful_connections_str.isdigit() else 0
    failed_connections = int(failed_connections_str) if failed_connections_str.isdigit() else 0
    
    # Discovery mode: enumerate items
    if params.get("_discover"):
        items = []
        # Operation status (single service, item="")
        items.append({"item": "", "params": {}, "metrics": []})
        # Expiration date (single service, item="")
        items.append({"item": "", "params": {}, "metrics": []})
        # Links (single service, item="")
        items.append({"item": "", "params": {"levels": ("no_levels", None)}, "metrics": ["connections"]})
        # Connected clients (single service, item="")
        items.append({"item": "", "params": {"levels": ("no_levels", None)}, "metrics": ["connections"]})
        # Connection rates (per-item: successful, failed)
        items.append({"item": "successful", "params": {}, "metrics": ["connections_rate"]})
        items.append({"item": "failed", "params": {}, "metrics": ["connections_rate"]})
        
        return {"changed": False, "msg": "discovered %d items" % len(items),
                "data": {"discovery": items}}
    
    # Check mode - determine which service/item to check
    item = params.get("item", "")
    levels = params.get("levels", ("no_levels", None))
    
    # NTLS Operation Status
    if item == "" and operation_status:
        if operation_status == "1":
            state = "OK"
            summary = "Running"
        elif operation_status == "2":
            state = "CRIT"
            summary = "Down"
        elif operation_status == "3":
            state = "UNKNOWN"
            summary = "Unknown"
        else:
            state = "UNKNOWN"
            summary = "Unknown operation status: " + operation_status
        
        return {"changed": False, "msg": summary,
                "data": {"state": state, "metrics": {}, "details": ""}}
    
    # NTLS Expiration Date
    if item == "" and not operation_status and expiration_date:
        return {"changed": False,
                "msg": "The NTLS server certificate expires on " + expiration_date,
                "data": {"state": "OK", "metrics": {}, "details": ""}}
    
    # NTLS Links
    if item == "" and levels and links_str:
        warn = None
        crit = None
        if type(levels) == "list" and len(levels) >= 2:
            warn = levels[0]
            crit = levels[1]
        elif type(levels) == "string" and levels == "no_levels":
            warn = None
            crit = None
        
        if warn != None and type(warn) == "int" and links >= warn:
            state = "CRIT" if crit != None and type(crit) == "int" and links >= crit else "WARN"
        elif crit != None and type(crit) == "int" and links >= crit:
            state = "CRIT"
        else:
            state = "OK"
        
        return {"changed": False,
                "msg": "%d links" % links,
                "data": {"state": state, "metrics": {"connections": links}, "details": ""}}
    
    # NTLS Connected Clients
    if item == "" and connected_clients_str:
        warn = None
        crit = None
        if type(levels) == "list" and len(levels) >= 2:
            warn = levels[0]
            crit = levels[1]
        elif type(levels) == "string" and levels == "no_levels":
            warn = None
            crit = None
        
        if warn != None and type(warn) == "int" and connected_clients >= warn:
            state = "CRIT" if crit != None and type(crit) == "int" and connected_clients >= crit else "WARN"
        elif crit != None and type(crit) == "int" and connected_clients >= crit:
            state = "CRIT"
        else:
            state = "OK"
        
        return {"changed": False,
                "msg": "%d connected clients" % connected_clients,
                "data": {"state": state, "metrics": {"connections": connected_clients}, "details": ""}}
    
    # NTLS Connection Rate (successful/failed)
    if item in ["successful", "failed"]:
        connections = successful_connections if item == "successful" else failed_connections
        # Since we can't use rate calculation from Checkmk in Starlark without persistent state,
        # report raw values; the agent should provide this data for rate calculation
        # In practice, for a single run, we can only report the cumulative value
        return {"changed": False,
                "msg": "%f connections/s" % float(connections),
                "data": {"state": "OK", "metrics": {"connections_rate": float(connections)}, "details": ""}}
    
    # No matching service found
    return {"changed": False, "msg": "no such service item",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}