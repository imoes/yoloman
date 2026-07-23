def main(ctx, params):
    # Constants
    SNMP_COMMUNITY = params.get("community", "public")
    SNMP_HOST = params.get("host", "localhost")
    OID_BASE = ".1.3.6.1.4.1.21239.5.1"
    
    # Discovery mode
    if params.get("_discover"):
        # Discover humidity sensors by walking the humidity data OID tree
        oid = OID_BASE + ".2.1.4"  # humidity values at .2.1.4.<sensor-id>
        res = ctx.run(["snmpwalk", "-v2c", "-c", SNMP_COMMUNITY, "-On", SNMP_HOST, oid], mutates=False)
        items = []
        
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            # Parse OID: .1.3.6.1.4.1.21239.5.1.2.1.4.<sensor-id>
            oid_part = parts[0].strip()
            if oid_part.startswith(OID_BASE + ".2.1.4."):
                sensor_id = oid_part.rsplit(".", 1)[-1]
                sensor_name = "Humidity " + sensor_id
                
                # Get description (OID .2.1.3.<sensor-id>)
                desc_oid = OID_BASE + ".2.1.3." + sensor_id
                desc_res = ctx.run(["snmpget", "-v2c", "-c", SNMP_COMMUNITY, "-On", SNMP_HOST, desc_oid], mutates=False)
                if desc_res.rc == 0 and desc_res.stdout.strip():
                    desc_parts = desc_res.stdout.strip().split(" = ")
                    if len(desc_parts) == 2:
                        desc_val = desc_parts[1].strip()
                        # Strip quotes if present
                        if desc_val.startswith('"') and desc_val.endswith('"'):
                            desc_val = desc_val[1:-1]
                        sensor_name = desc_val
                
                items.append({
                    "item": sensor_name,
                    "params": {
                        "levels": [50.0, 55.0],
                        "levels_lower": [10.0, 15.0]
                    },
                    "metrics": ["humidity"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d humidity sensors" % len(items),
            "data": {"discovery": items}
        }
    
    # Check mode - extract item and parameters
    item = params.get("item", "")
    warn, crit = params.get("levels", [50.0, 55.0])
    warn_lower, crit_lower = params.get("levels_lower", [10.0, 15.0])
    
    # Extract sensor id from item name (format: "Humidity <id>" or custom name)
    sensor_id = ""
    if item.startswith("Humidity "):
        sensor_id = item.split(" ", 1)[-1]
    else:
        # Try to find sensor id by looking for the first number in the item name
        for i, c in enumerate(item):
            if c.isdigit():
                # Extract contiguous digits
                j = i
                while j < len(item) and item[j].isdigit():
                    j += 1
                sensor_id = item[i:j]
                break
    
    # If no sensor id found, try to use the item itself as sensor_id
    if not sensor_id.isdigit():
        # Try to find by walking general description OID
        desc_oid = OID_BASE + ".2.1.3"
        desc_res = ctx.run(["snmpwalk", "-v2c", "-c", SNMP_COMMUNITY, "-On", SNMP_HOST, desc_oid], mutates=False)
        for line in desc_res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            val_part = parts[1].strip()
            # Strip quotes if present
            if val_part.startswith('"') and val_part.endswith('"'):
                val_part = val_part[1:-1]
            if val_part == item:
                sensor_id = oid_part.rsplit(".", 1)[-1]
                break
    
    # Get humidity value from OID .2.1.4.<sensor-id>
    oid = OID_BASE + ".2.1.4." + sensor_id
    res = ctx.run(["snmpget", "-v2c", "-c", SNMP_COMMUNITY, "-On", SNMP_HOST, oid], mutates=False)
    
    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "humidity sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse humidity value
    parts = res.stdout.strip().split(" = ")
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "unable to parse humidity value: " + res.stdout,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    humidity_str = parts[1].strip()
    # Convert to int (sometimes会有 extra whitespace or be quoted)
    humidity_str = humidity_str.strip('"').strip()
    if not humidity_str.isdigit():
        return {
            "changed": False,
            "msg": "invalid humidity value: " + humidity_str,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    humidity = int(humidity_str)
    
    # Determine state based on thresholds
    if humidity <= crit_lower or humidity >= crit:
        state = "CRIT"
    elif humidity <= warn_lower or humidity >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    # Build message
    summary = "%f%%" % float(humidity)
    if state != "OK":
        if humidity >= warn:
            summary += " (warn/crit at %f/%f)" % (warn, crit)
        else:
            summary += " (warn/crit below %f/%f)" % (warn_lower, crit_lower)
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"humidity": float(humidity)},
            "details": ""
        }
    }