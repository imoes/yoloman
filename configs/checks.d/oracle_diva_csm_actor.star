def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        # Fetch actor section: base .1.3.6.1.4.1.110901.1.3.1.1, oids ["2","4"]
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On", host,
            ".1.3.6.1.4.1.110901.1.3.1.1"
        ], mutates=False)
        
        items = []
        for line in res.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            oid_full, value_str = parts
            # Extract the last numeric part (element id) from OID
            oid_tail = oid_full.rsplit(".", 1)[-1]
            # Value is like "INTEGER: 1" or "STRING: ..."
            value_type, value = value_str.split(": ", 1) if ": " in value_str else (value_str, "")
            value = value.strip().strip('"')
            if oid_tail.isdigit():
                element_id = oid_tail
                item_name = "Actor " + element_id
                items.append({
                    "item": item_name,
                    "params": {},
                    "metrics": []
                })
        
        return {
            "changed": False,
            "msg": "discovered %d actors" % len(items),
            "data": {"discovery": items}
        }
    
    # Check mode
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    item = params.get("item", "")
    
    # Fetch only actor status values: OID .1.3.6.1.4.1.110901.1.3.1.1.2 (index 2)
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On", host,
        ".1.3.6.1.4.1.110901.1.3.1.1.2"
    ], mutates=False)
    
    found = False
    for line in res.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        oid_full, value_str = parts
        # Extract the last numeric part (element id) from OID
        oid_tail = oid_full.rsplit(".", 1)[-1]
        value_type, value = value_str.split(": ", 1) if ": " in value_str else (value_str, "")
        value = value.strip().strip('"')
        if not value.isdigit():
            continue
        
        # Build item name as in the original: "Actor <element_id>"
        element_id = oid_tail
        check_item_name = "Actor " + element_id
        
        if check_item_name == item:
            found = True
            reading = value
            if reading == "1":
                state = "OK"
                summary = "online"
            elif reading == "2":
                state = "CRIT"
                summary = "offline"
            elif reading == "3":
                state = "WARN"
                summary = "unknown"
            else:
                state = "UNKNOWN"
                summary = "unexpected state"
            
            return {
                "changed": False,
                "msg": summary,
                "data": {
                    "state": state,
                    "metrics": {},
                    "details": ""
                }
            }
    
    if not found:
        return {
            "changed": False,
            "msg": "actor not found",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }