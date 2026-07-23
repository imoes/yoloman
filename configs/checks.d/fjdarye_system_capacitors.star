# ===== Starlark check module: fjdarye_system_capacitors =====

# SNMP base OIDs for supported Fujitsu storage systems
FJDARYE_SYSTEM_CAPACITORS = {
    ".1.3.6.1.4.1.211.1.21.1.60": ".2.5.2.1",   # fjdarye60
    ".1.3.6.1.4.1.211.1.21.1.100": ".2.9.2.1",  # fjdarye100
    ".1.3.6.1.4.1.211.1.21.1.101": ".2.9.2.1",  # fjdarye101
    ".1.3.6.1.4.1.211.1.21.1.150": ".2.5.2.1",  # fjdarye500
    ".1.3.6.1.4.1.211.1.21.1.153": ".2.5.2.1",  # fjdarye600
}

# Status mapping: status_code -> (state, summary)
FJDARYE_ITEM_STATUS = {
    "1": ("OK", "Normal"),
    "2": ("CRIT", "Alarm"),
    "3": ("WARN", "Warning"),
    "4": ("CRIT", "Invalid"),
    "5": ("CRIT", "Maintenance"),
    "6": ("CRIT", "Undefined"),
}


def _discover_system_capacitors(ctx, params):
    """Gather all system capacitors via SNMP and enumerate items."""
    # Try each device OID mapping to collect capacitor entries
    discovered = []
    
    # Build a list of base OIDs to query
    base_oids = []
    for device_oid, capa_oid in FJDARYE_SYSTEM_CAPACITORS.items():
        base_oids.append(device_oid + capa_oid)
    
    # Query all base OIDs
    for base_oid in base_oids:
        # Use snmpwalk for the base OID
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), base_oid
        ], mutates=False)
        
        if res.rc != 0:
            continue
            
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
                
            # Parse line: <OID>.<index> = INTEGER: <status>
            # Example: .1.3.6.1.4.1.211.1.21.1.60.2.5.2.1.1.1 = INTEGER: 1
            # We want index and status
            parts = line.split()
            if len(parts) < 4:
                continue
                
            # Extract index from OID
            full_oid = parts[0].rstrip("=").strip()
            # The index is the last component after the base OID
            # Split by '.' and get the index part (last numeric segment)
            segments = full_oid.split('.')
            # Base OID segments: e.g., ['1','3','6','1','4','1','211','1','21','1','60','2','5','2','1']
            # We need to strip the base part to get the index
            # Find where our base_oid starts in the full_oid
            base_segments = base_oid.split('.')
            idx_segments = segments[len(base_segments):]
            if not idx_segments:
                continue
                
            item_index = idx_segments[0]  # First segment after base is the index
            
            # Get status from the value part
            status = parts[-1] if len(parts) >= 4 else ""
            
            # Skip invalid items (status == "4")
            if status == "4":
                continue
                
            # Add to discovered list
            discovered.append({
                "item": item_index,
                "params": {},
                "metrics": []
            })
    
    return discovered


def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        discovered = _discover_system_capacitors(ctx, params)
        return {
            "changed": False,
            "msg": "discovered %d system capacitors" % len(discovered),
            "data": {"discovery": discovered}
        }
    
    # Check mode
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Try each device OID mapping to find the requested item
    for device_oid, capa_oid in FJDARYE_SYSTEM_CAPACITORS.items():
        base_oid = device_oid + capa_oid
        
        # Use snmpget for the specific item OID
        item_oid = base_oid + "." + item
        res = ctx.run([
            "snmpget", "-v2c", "-c", community,
            "-On", host, item_oid
        ], mutates=False)
        
        if res.rc != 0:
            continue
            
        # Parse the result
        line = res.stdout.strip()
        if not line:
            continue
            
        # Expected format: <OID>.<index> = INTEGER: <status>
        parts = line.split()
        if len(parts) < 4:
            continue
            
        # Get status from the last part
        status = parts[-1] if len(parts) >= 4 else ""
        
        # Look up the status
        status_info = FJDARYE_ITEM_STATUS.get(status, ("UNKNOWN", "Unknown"))
        state, summary = status_info
        
        return {
            "changed": False,
            "msg": "%s %s" % (item, summary),
            "data": {
                "state": state,
                "metrics": {},
                "details": ""
            }
        }
    
    # Item not found
    return {
        "changed": False,
        "msg": "no such capacitor unit: " + item,
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": ""
        }
    }
