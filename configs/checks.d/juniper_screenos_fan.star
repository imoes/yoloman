def main(ctx, params):
    # Base OID for Juniper ScreenOS fan status
    base_oid = ".1.3.6.1.4.1.3224.21.2.1"
    # OIDs: index (fan number) and status
    index_oid = base_oid + ".3"
    status_oid = base_oid + ".2"
    
    # Discover fans by walking the index OID
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), index_oid
        ], mutates=False)
        
        if res.rc != 0:
            fail("snmpwalk failed: " + res.stderr)
        
        fans = []
        for line in res.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) < 2:
                continue
            # OID format: .1.3.6.1.4.1.3224.21.2.1.3.X = INTEGER: X
            oid_val = parts[0]
            # Extract fan number from OID end (e.g., .3.1 -> 1)
            parts_oid = oid_val.rsplit(".", 1)
            if len(parts_oid) != 2:
                continue
            fan_id = parts_oid[1]
            if not fan_id.isdigit():
                continue
            fans.append({"item": fan_id, "params": {}, "metrics": []})
        
        return {
            "changed": False,
            "msg": "discovered %d fans" % len(fans),
            "data": {"discovery": fans}
        }
    
    # Normal check mode
    item = params.get("item", "")
    if item == None:
        item = ""
    
    # Walk status OID to find requested fan
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), status_oid
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "snmpwalk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse SNMP output for the requested fan
    fan_status = None
    for line in res.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) < 2:
            continue
        oid_val = parts[0]
        status_val = parts[1]
        
        # Extract fan number from OID
        # OID format: .1.3.6.1.4.1.3224.21.2.1.2.X = INTEGER: status
        parts_oid = oid_val.rsplit(".", 1)
        if len(parts_oid) != 2:
            continue
        fan_id = parts_oid[1]
        
        if fan_id == item:
            # Extract integer value (strip "INTEGER:" or just take the number)
            if ":" in status_val:
                status_str = status_val.split(":", 1)[1].strip()
            else:
                status_str = status_val
            fan_status = status_str
            break
    
    # Determine state
    if fan_status == None:
        return {
            "changed": False,
            "msg": "fan %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    if fan_status == "1":
        state = "OK"
        msg_summary = "status is good"
    elif fan_status == "2":
        state = "CRIT"
        msg_summary = "status is failed"
    else:
        state = "CRIT"
        msg_summary = "Unknown fan status " + str(fan_status)
    
    return {
        "changed": False,
        "msg": msg_summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }