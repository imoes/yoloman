def main(ctx, params):
    _FIELDS = ["bcast", "mcast", "0-63b", "64-127b", "128-255b", "256-511b", "512-1023b", "1024-1518b"]
    
    def _to_int(value):
        stripped = value.replace(" Packets", "").strip()
        return int(stripped) if stripped else 0
    
    base_oid = ".1.3.6.1.2.1.16.1.1.1"
    oids = [
        ".1.3.6.1.2.1.16.1.1.1.1",
        ".1.3.6.1.2.1.16.1.1.1.6",
        ".1.3.6.1.2.1.16.1.1.1.7",
        ".1.3.6.1.2.1.16.1.1.1.14",
        ".1.3.6.1.2.1.16.1.1.1.15",
        ".1.3.6.1.2.1.16.1.1.1.16",
        ".1.3.6.1.2.1.16.1.1.1.17",
        ".1.3.6.1.2.1.16.1.1.1.18",
        ".1.3.6.1.2.1.16.1.1.1.19"
    ]
    
    if params.get("_discover"):
        sys_descr = ""
        sys_objectid = ""
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                      "-On", params.get("host", "localhost"), ".1.3.6.1.2.1.1.1.0"], mutates=False)
        if res.rc == 0:
            parts = res.stdout.strip().split(" = ", 1)
            if len(parts) == 2:
                sys_descr = parts[1].strip()
        
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                      "-On", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if res.rc == 0:
            parts = res.stdout.strip().split(" = ", 1)
            if len(parts) == 2:
                sys_objectid = parts[1].strip()
        
        is_cisco = sys_descr.startswith("cisco") if sys_descr else False
        is_trulink = (sys_objectid == ".1.3.6.1.4.1.11863.1.1.3") if sys_objectid else False
        if not (is_cisco or is_trulink):
            return {"changed": False, "msg": "discovered 0 items (device not Cisco/Trulink)",
                    "data": {"discovery": []}}
        
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                      "-On", params.get("host", "localhost"), ".1.3.6.1.2.1.16.19.12.0"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items (no RMON data)",
                    "data": {"discovery": []}}
        
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                      "-On", params.get("host", "localhost")] + oids, mutates=False)
        
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items (SNMP walk failed)",
                    "data": {"discovery": []}}
        
        lines = res.stdout.strip().split("\n") if res.stdout.strip() else []
        if not lines:
            return {"changed": False, "msg": "discovered 0 items (empty response)",
                    "data": {"discovery": []}}
        
        data_by_index = {}
        field_idx_map = {
            "6": "bcast",
            "7": "mcast",
            "14": "0-63b",
            "15": "64-127b",
            "16": "128-255b",
            "17": "256-511b",
            "18": "512-1023b",
            "19": "1024-1518b"
        }
        
        for line in lines:
            line = line.strip()
            if not line or "=" not in line:
                continue
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            
            if oid_part.startswith(base_oid + "."):
                suffix = oid_part[len(base_oid) + 1:]
                idx_parts = suffix.split(".", 1)
                if len(idx_parts) != 2:
                    continue
                index_part = idx_parts[0]
                field_part = idx_parts[1]
                
                if ": " in value_part:
                    value = value_part.split(": ", 1)[1].strip()
                else:
                    value = value_part.strip()
                
                if field_part in field_idx_map:
                    field_name = field_idx_map[field_part]
                    if index_part not in data_by_index:
                        data_by_index[index_part] = {f: "0" for f in _FIELDS}
                    data_by_index[index_part][field_name] = value
        
        discovery = []
        for index, stats in data_by_index.items():
            found_nonzero = False
            for f in _FIELDS:
                if stats[f] != "0":
                    found_nonzero = True
                    break
            if found_nonzero:
                item = "port-" + index
                discovery.append({
                    "item": item,
                    "params": {},
                    "metrics": _FIELDS
                })
        
        return {"changed": False, "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}
    
    # Check mode
    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    sys_descr = ""
    sys_objectid = ""
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                  "-On", params.get("host", "localhost"), ".1.3.6.1.2.1.1.1.0"], mutates=False)
    if res.rc == 0:
        parts = res.stdout.strip().split(" = ", 1)
        if len(parts) == 2:
            sys_descr = parts[1].strip()
    
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                  "-On", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if res.rc == 0:
        parts = res.stdout.strip().split(" = ", 1)
        if len(parts) == 2:
            sys_objectid = parts[1].strip()
    
    is_cisco = sys_descr.startswith("cisco") if sys_descr else False
    is_trulink = (sys_objectid == ".1.3.6.1.4.1.11863.1.1.3") if sys_objectid else False
    if not (is_cisco or is_trulink):
        return {"changed": False, "msg": "device not Cisco/Trulink",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                  "-On", params.get("host", "localhost"), ".1.3.6.1.2.1.16.19.12.0"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "RMON tree not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                  "-On", params.get("host", "localhost")] + oids, mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    lines = res.stdout.strip().split("\n") if res.stdout.strip() else []
    if not lines:
        return {"changed": False, "msg": "empty response",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    data_by_index = {}
    field_idx_map = {
        "6": "bcast",
        "7": "mcast",
        "14": "0-63b",
        "15": "64-127b",
        "16": "128-255b",
        "17": "256-511b",
        "18": "512-1023b",
        "19": "1024-1518b"
    }
    
    for line in lines:
        line = line.strip()
        if not line or "=" not in line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        
        if oid_part.startswith(base_oid + "."):
            suffix = oid_part[len(base_oid) + 1:]
            idx_parts = suffix.split(".", 1)
            if len(idx_parts) != 2:
                continue
            index_part = idx_parts[0]
            field_part = idx_parts[1]
            
            if ": " in value_part:
                value = value_part.split(": ", 1)[1].strip()
            else:
                value = value_part.strip()
            
            if field_part in field_idx_map:
                field_name = field_idx_map[field_part]
                if index_part not in data_by_index:
                    data_by_index[index_part] = {f: "0" for f in _FIELDS}
                data_by_index[index_part][field_name] = value
    
    item_idx = None
    for index, stats in data_by_index.items():
        if "port-" + index == item:
            item_idx = index
            break
    
    if item_idx == None:
        return {"changed": False, "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    stats = data_by_index[item_idx]
    parsed_stats = {}
    for f in _FIELDS:
        parsed_stats[f] = _to_int(stats[f])
    
    metrics = {}
    details_parts = []
    for metric_name in _FIELDS:
        value = parsed_stats.get(metric_name, 0)
        metrics[metric_name] = value
        details_parts.append(metric_name + ": " + str(value))
    
    msg = ", ".join(details_parts)
    
    return {"changed": False, "msg": msg,
            "data": {"state": "OK", "metrics": metrics, "details": ""}}