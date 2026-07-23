def main(ctx, params):
    # SNMP base OIDs for Fujitsu storage systems
    FJDARYE_SUPPORTED_DEVICES = [
        ".1.3.6.1.4.1.211.1.21.1.60",   # fjdarye60
        ".1.3.6.1.4.1.211.1.21.1.150",  # fjdarye500
        ".1.3.6.1.4.1.211.1.21.1.153",  # fjdarye600
    ]
    
    # Status mapping: status_code -> (summary, state)
    FJDARYE_ITEM_STATUS = {
        "1": ("Normal", "OK"),
        "2": ("Alarm", "CRIT"),
        "3": ("Warning", "WARN"),
        "4": ("Invalid", "CRIT"),
        "5": ("Maintenance", "CRIT"),
        "6": ("Undefined", "CRIT"),
    }
    
    # Discovery mode
    if params.get("_discover"):
        items = []
        for device_oid in FJDARYE_SUPPORTED_DEVICES:
            # Fetch index and status for expanders
            res = ctx.run([
                "snmpwalk",
                "-v2c",
                "-c", params.get("community", "public"),
                "-On",
                params.get("host", "localhost"),
                device_oid + ".2.8.2.1"
            ], mutates=False)
            
            if res.rc != 0:
                continue
                
            for line in res.stdout.splitlines():
                # Format: OID = STRING: "index value" or similar
                # We need to extract the index and status
                parts = line.split(" = ")
                if len(parts) != 2:
                    continue
                    
                oid_part = parts[0].strip()
                value_part = parts[1].strip()
                
                # Get the index part (last component of OID after .1)
                oid_suffix = oid_part.rsplit(".", 1)[-1]
                if oid_suffix == "1":
                    index = value_part.strip('"')
                    # Now look for status (.3)
                    # We need to find the matching status OID (index + 2)
                    # Since snmpwalk returns all in order, we can use the index pattern
                    pass
                elif oid_suffix == "3":
                    status = value_part.strip('"')
                    # Find corresponding index (subtract 2 from suffix)
                    base_oid = oid_part.rsplit(".", 1)[0]
                    index_oid = base_oid + ".1"
                    # We'll collect indices and statuses separately
                    # But since we have to do this in one pass, let's restructure
            
        # Let's redo discovery with a more robust approach
        items = []
        for device_oid in FJDARYE_SUPPORTED_DEVICES:
            # Fetch index and status for expanders
            # We'll fetch the entire subtree and process pairs
            base_oid = device_oid + ".2.8.2.1"
            res = ctx.run([
                "snmpwalk",
                "-v2c",
                "-c", params.get("community", "public"),
                "-On",
                params.get("host", "localhost"),
                base_oid
            ], mutates=False)
            
            if res.rc != 0:
                continue
                
            entries = {}
            for line in res.stdout.splitlines():
                if " = " not in line:
                    continue
                oid_part, value_part = line.split(" = ", 1)
                oid_parts = oid_part.split(".")
                if len(oid_parts) < 2:
                    continue
                # Last part is the OID instance
                suffix = oid_parts[-1]
                if suffix == "1":
                    # Index entry
                    # Extract index value (strip quotes if present)
                    index_val = value_part.strip().strip('"')
                    entries[index_val] = None
                elif suffix == "3":
                    # Status entry
                    # Find the corresponding index by removing the offset
                    # OID structure is base.1=index, base.3=status
                    # So if we have base.X.3, we need base.X.1
                    # But we can't easily reconstruct base.X from base.X.3
                    # Let's try a different approach: parse snmpwalk output
                    pass
            
        # Alternative approach: use snmpwalk to get just the table, parse carefully
        # Actually, let's use the same pattern as the original check:
        # The MIB defines .1 as Index, .3 as Status
        # snmpwalk will return lines in order, so we can pair them
        items = []
        for device_oid in FJDARYE_SUPPORTED_DEVICES:
            # Fetch the specific tree for expanders
            res = ctx.run([
                "snmpwalk",
                "-v2c",
                "-c", params.get("community", "public"),
                "-On",
                params.get("host", "localhost"),
                device_oid + ".2.8.2.1"
            ], mutates=False)
            
            if res.rc != 0:
                continue
                
            indices = []
            statuses = []
            for line in res.stdout.splitlines():
                if " = " not in line:
                    continue
                oid_part, value_part = line.split(" = ", 1)
                oid_suffix = oid_part.rsplit(".", 1)[-1]
                if oid_suffix == "1":
                    indices.append(value_part.strip().strip('"'))
                elif oid_suffix == "3":
                    statuses.append(value_part.strip().strip('"'))
            
            # Pair up indices and statuses
            for idx, status in zip(indices, statuses):
                if status != "4":  # skip invalid items for discovery
                    items.append({
                        "item": idx,
                        "params": {},
                        "metrics": []
                    })
        
        return {
            "changed": False,
            "msg": "discovered %d expanders" % len(items),
            "data": {"discovery": items}
        }
    
    # Check mode
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # We need to find which device this expander belongs to
    # Try all supported devices to find the matching expander
    found_item = None
    found_status = None
    
    for device_oid in FJDARYE_SUPPORTED_DEVICES:
        # Get the expander table for this device
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On",
            host,
            device_oid + ".2.8.2.1"
        ], mutates=False)
        
        if res.rc != 0:
            continue
        
        indices = []
        statuses = []
        for line in res.stdout.splitlines():
            if " = " not in line:
                continue
            oid_part, value_part = line.split(" = ", 1)
            oid_suffix = oid_part.rsplit(".", 1)[-1]
            if oid_suffix == "1":
                indices.append(value_part.strip().strip('"'))
            elif oid_suffix == "3":
                statuses.append(value_part.strip().strip('"'))
        
        # Find our item
        for idx, status in zip(indices, statuses):
            if idx == item:
                found_item = idx
                found_status = status
                break
        
        if found_item != None:
            break
    
    # If not found, return UNKNOWN
    if found_item == None:
        return {
            "changed": False,
            "msg": "expander '%s' not found" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Map status to state and summary
    status_data = FJDARYE_ITEM_STATUS.get(found_status, ("Unknown", "UNKNOWN"))
    summary, state = status_data
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }
