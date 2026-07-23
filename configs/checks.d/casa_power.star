def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.4.1.20858.10.33.1.5.1.4"
        
        # Walk the SNMP OID for power supply statuses
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        
        items = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            # Extract numeric index from OID: .1.3.6.1.4.1.20858.10.33.1.5.1.4.1 -> 1
            oid_part = parts[0].strip()
            # Find last dot-separated number in the OID
            last_dot = oid_part.rfind(".")
            if last_dot >= 0:
                idx_str = oid_part[last_dot+1:]
                if idx_str.isdigit():
                    idx = int(idx_str)
                    items.append({
                        "item": str(idx),
                        "params": {},
                        "metrics": []
                    })
        
        return {"changed": False, "msg": "discovered %d power supplies" % len(items),
                "data": {"discovery": items}}
    
    # Check mode
    item = params.get("item", "")
    if not item.isdigit():
        return {"changed": False, "msg": "invalid item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    unit_nr = int(item)
    
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.20858.10.33.1.5.1.4"
    oid = base_oid + "." + item
    
    # Get specific power supply status
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, oid], mutates=False)
    
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "Power Supply %s not found in snmp output" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse output: .1.3.6.1.4.1.20858.10.33.1.5.1.4.1 = INTEGER: 1
    parts = res.stdout.strip().split(" = ")
    if len(parts) < 2:
        return {"changed": False, "msg": "Power Supply %s not found in snmp output" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    value_part = parts[1].strip()
    # Extract value after ':'
    colon_pos = value_part.find(":")
    if colon_pos >= 0:
        status_str = value_part[colon_pos+1:].strip()
    else:
        status_str = ""
    
    if not status_str.isdigit():
        return {"changed": False, "msg": "Power Supply %s not found in snmp output" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    status = int(status_str)
    status_map = {
        "0": "Power supply - Unknown status",
        "1": "Power supply OK",
        "2": "Power supply working under threshold",
        "3": "Power supply working over threshold",
        "4": "Power failure"
    }
    
    state_map = {
        "0": "UNKNOWN",
        "1": "OK",
        "2": "OK",
        "3": "WARN",
        "4": "CRIT"
    }
    
    summary = status_map.get(str(status), "Power supply - Unknown status")
    state = state_map.get(str(status), "UNKNOWN")
    
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {}, "details": ""}}
