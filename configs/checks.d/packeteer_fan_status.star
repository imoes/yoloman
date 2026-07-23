def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.2334.2.1.5"
        ], mutates=False)
        
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed",
                    "data": {"discovery": []}}
        
        fans = []
        for line in res.stdout.splitlines():
            stripped = line.strip()
            if not stripped:
                continue
            parts = stripped.split(" = ")
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            val = ""
            if value_part.startswith("INTEGER: "):
                val = value_part[len("INTEGER: "):].strip()
            elif value_part.startswith("INTEGER "):
                val = value_part[len("INTEGER "):].strip()
            else:
                val = value_part.strip()
            
            if oid_part.startswith(".1.3.6.1.4.1.2334.2.1.5.12."):
                idx_str = oid_part[35:]
                if idx_str.isdigit():
                    fans.append((int(idx_str), val))
            elif oid_part.startswith(".1.3.6.1.4.1.2334.2.1.5.22."):
                idx_str = oid_part[35:]
                if idx_str.isdigit():
                    fans.append((int(idx_str), val))
        
        seen_indices = set()
        fan_status_list = []
        for idx, status in sorted(fans, key=lambda x: x[0]):
            if idx not in seen_indices:
                seen_indices.add(idx)
                fan_status_list.append(status)
        
        items = []
        for idx, status in enumerate(fan_status_list):
            if status in ["1", "2"]:
                items.append({"item": str(idx), "params": {}, "metrics": []})
        
        return {"changed": False, "msg": "discovered %d fans" % len(items),
                "data": {"discovery": items}}
    
    item = params.get("item", "")
    if not item.isdigit():
        return {"changed": False, "msg": "invalid item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    idx = int(item)
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    oid = ".1.3.6.1.4.1.2334.2.1.5.12." + str(idx)
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, oid
    ], mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP get failed for fan " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    output = res.stdout.strip()
    if not output:
        return {"changed": False, "msg": "empty SNMP response for fan " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    parts = output.split(" = ")
    if len(parts) != 2:
        return {"changed": False, "msg": "unparseable SNMP response: " + output,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    value_part = parts[1].strip()
    status = ""
    if value_part.startswith("INTEGER: "):
        status = value_part[len("INTEGER: "):].strip()
    elif value_part.startswith("INTEGER "):
        status = value_part[len("INTEGER "):].strip()
    else:
        status = value_part.strip()
    
    if status == "1":
        return {"changed": False, "msg": "OK",
                "data": {"state": "OK", "metrics": {}, "details": ""}}
    elif status == "2":
        return {"changed": False, "msg": "Not OK",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    elif status == "3":
        return {"changed": False, "msg": "Not present",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    else:
        return {"changed": False, "msg": "Unknown status: " + status,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}