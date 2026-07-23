def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: walk the SNMP tree for arbor_peakflow_tms_updates
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.9694.1.5.5"
        ], mutates=False)
        
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)
        
        # Parse output: map OIDs 1.2.0 (Device) and 2.1.0 (Mitigation)
        device_oid = ".1.3.6.1.4.1.9694.1.5.5.1.2.0"
        mitigation_oid = ".1.3.6.1.4.1.9694.1.5.5.2.1.0"
        
        device_val = ""
        mitigation_val = ""
        
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            # Split on '=' to get OID and value parts
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            val_part = parts[1].strip()
            # Extract value (remove type prefix like "STRING:" or "INTEGER:")
            if ":" in val_part:
                val_part = val_part.split(":", 1)[1].strip()
            # Remove quotes if present
            if val_part.startswith('"') and val_part.endswith('"'):
                val_part = val_part[1:-1]
            
            if oid_part.endswith(device_oid):
                device_val = val_part
            elif oid_part.endswith(mitigation_oid):
                mitigation_val = val_part
        
        # Build discovery list per item (Device, Mitigation)
        out = []
        if device_val != "":
            out.append({"item": "Device", "params": {}, "metrics": []})
        if mitigation_val != "":
            out.append({"item": "Mitigation", "params": {}, "metrics": []})
        
        return {
            "changed": False,
            "msg": "discovered %d items" % len(out),
            "data": {"discovery": out}
        }
    
    # Check mode: single item
    item = params.get("item", "")
    res = ctx.run([
        "snmpget",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.9694.1.5.5.1.2.0" if item == "Device" else ".1.3.6.1.4.1.9694.1.5.5.2.1.0"
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP get failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse single value
    line = res.stdout.strip()
    parts = line.split(" = ", 1)
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "parse error",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    val_part = parts[1].strip()
    if ":" in val_part:
        val_part = val_part.split(":", 1)[1].strip()
    if val_part.startswith('"') and val_part.endswith('"'):
        val_part = val_part[1:-1]
    
    # For unknown items, return UNKNOWN
    if item != "Device" and item != "Mitigation":
        return {
            "changed": False,
            "msg": "unknown item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    return {
        "changed": False,
        "msg": val_part,
        "data": {"state": "OK", "metrics": {}, "details": ""}
    }
