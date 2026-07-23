def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.231.2.10.2.11.3.1.1.2"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", 
                    "data": {"discovery": []}}
        
        items = []
        for line in res.stdout.splitlines():
            if not line or " = " not in line:
                continue
            value_part = line.split(" = ", 1)[1]
            if ":" in value_part:
                value_str = value_part.split(":", 1)[1].strip().strip('"')
            else:
                value_str = value_part.strip()
            if value_str:
                items.append({"item": value_str, "params": {},
                              "metrics": []})
        
        return {"changed": False, "msg": "discovered %d subsystems" % len(items),
                "data": {"discovery": items}}
    
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.231.2.10.2.11.3.1.1"
    ], mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    name_map = {}
    status_map = {}
    for line in res.stdout.splitlines():
        if not line or " = " not in line:
            continue
        oid_part, value_part = line.split(" = ", 1)
        suffix = oid_part.split(".")[-1]
        if ":" in value_part:
            value_str = value_part.split(":", 1)[1].strip().strip('"')
        else:
            value_str = value_part.strip()
        if suffix == "2":
            parts = oid_part.split(".")
            if len(parts) >= 14:
                idx = parts[-1]
                name_map[idx] = value_str
        elif suffix == "3":
            parts = oid_part.split(".")
            if len(parts) >= 14:
                idx = parts[-1]
                status_map[idx] = value_str
    
    found_idx = ""
    for idx, name_val in name_map.items():
        if name_val == item:
            found_idx = idx
            break
    
    if not found_idx:
        return {"changed": False, "msg": "subsystem not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    status_str = status_map.get(found_idx, "")
    if not status_str:
        return {"changed": False, "msg": "Status not found in SNMP data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    status = int(status_str) if status_str.isdigit() else None
    if status == None:
        return {"changed": False, "msg": "Status not found in SNMP data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    status_map_dict = {
        1: "ok",
        2: "degraded",
        3: "error",
        4: "failed",
        5: "unknown-init"
    }
    statusname = status_map_dict.get(status, "invalid")
    
    if status in [1, 5]:
        state = "OK"
        summary = statusname + " - no problems"
    elif (status >= 2) and (status <= 4):
        state = "CRIT"
        summary = statusname
    else:
        state = "UNKNOWN"
        summary = "unknown status " + str(status)
    
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {}, "details": ""}}