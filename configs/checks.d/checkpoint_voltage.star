# ===== Starlark translation of Checkmk checkpoint_voltage check =====
# SNMP-based voltage monitor for Check Point devices
# OID base: .1.3.6.1.4.1.2620.1.6.7.8.3.1
# OIDs: 2=name, 3=value, 4=unit, 6=device_status

SENSOR_STATUS_TO_CMK_STATUS = {
    "0": ("OK", "sensor in range"),
    "1": ("CRIT", "sensor out of range"),
    "2": ("UNKNOWN", "reading error"),
}

def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        # Fetch voltage table: name, value, unit, device_status
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.2620.1.6.7.8.3.1"
        ], mutates=False)
        
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed: " + res.stderr,
                    "data": {"discovery": []}}
        
        # Parse snmpwalk output: OID = type: value
        # We need to group consecutive OIDs that belong to the same entry
        # OID structure: .1.3.6.1.4.1.2620.1.6.7.8.3.1.{index}.{suboid}
        # suboids: 2=name, 3=value, 4=unit, 6=device_status
        
        # Extract data by OID suffix pattern
        data = {}
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line or "=" not in line:
                continue
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid, value = parts
            oid = oid.strip()
            value = value.strip()
            # Extract suffix from OID: .1.3.6.1.4.1.2620.1.6.7.8.3.1.{index}.{suboid}
            # Skip base and get the rest
            if not oid.startswith(".1.3.6.1.4.1.2620.1.6.7.8.3.1."):
                continue
            suffix = oid[len(".1.3.6.1.4.1.2620.1.6.7.8.3.1."):]
            if "." not in suffix:
                continue
            idx_part, suboid = suffix.split(".", 1)
            # Only process expected suboids (2,3,4,6)
            if suboid not in ["2", "3", "4", "6"]:
                continue
            
            # Remove quotes if present
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
            
            # Initialize index entry if needed
            if idx_part not in data:
                data[idx_part] = {}
            data[idx_part][suboid] = value
        
        # Build discovery list
        discovery = []
        for idx_part, entry in data.items():
            name = entry.get("2", "").strip()
            if not name:
                continue
            # Check if it's a valid voltage sensor entry
            # At minimum should have name (OID 2)
            params_default = {"warn": None, "crit": None}
            metrics = []  # no perfdata metrics for this check
            discovery.append({
                "item": name,
                "params": params_default,
                "metrics": metrics
            })
        
        return {"changed": False, "msg": "discovered %d voltage sensors" % len(discovery),
                "data": {"discovery": discovery}}
    
    # Normal check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Fetch full voltage table
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.2620.1.6.7.8.3.1"
    ], mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse snmpwalk output
    data = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid, value = parts
        oid = oid.strip()
        value = value.strip()
        if not oid.startswith(".1.3.6.1.4.1.2620.1.6.7.8.3.1."):
            continue
        suffix = oid[len(".1.3.6.1.4.1.2620.1.6.7.8.3.1."):]
        if "." not in suffix:
            continue
        idx_part, suboid = suffix.split(".", 1)
        if suboid not in ["2", "3", "4", "6"]:
            continue
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        if idx_part not in data:
            data[idx_part] = {}
        data[idx_part][suboid] = value
    
    # Find matching item
    state = "UNKNOWN"
    summary = "no matching sensor"
    for idx_part, entry in data.items():
        name = entry.get("2", "").strip()
        if name == item:
            value = entry.get("3", "").strip()
            unit = entry.get("4", "").strip()
            dev_status = entry.get("6", "2").strip()  # default to reading error if missing
            
            # Map status
            status_info = SENSOR_STATUS_TO_CMK_STATUS.get(dev_status, ("UNKNOWN", "unknown status"))
            state = status_info[0]
            summary = "Status: %s, %s %s" % (status_info[1], value, unit)
            break
    
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {}, "details": ""}}
