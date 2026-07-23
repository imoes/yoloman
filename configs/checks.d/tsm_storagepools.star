def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/tsm_storagepools"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to read tsm_storagepools data",
                    "data": {"discovery": []}}
        
        items = []
        for line in res.stdout.splitlines():
            parts = line.split()
            if len(parts) < 4:
                continue
            
            inst = parts[0]
            stype = parts[1]
            name = parts[2]
            size = parts[3]
            
            item = name if inst == "default" else inst + " / " + name
            items.append({
                "item": item,
                "params": {},
                "metrics": ["used_space"]
            })
        
        return {"changed": False, "msg": "discovered %d storagepools" % len(items),
                "data": {"discovery": items}}
    
    item = params.get("item", "")
    
    res = ctx.run(["cat", "/proc/tsm_storagepools"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to read tsm_storagepools data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    parsed = {}
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        
        inst = parts[0]
        stype = parts[1]
        name = parts[2]
        size = parts[3]
        
        item_key = name if inst == "default" else inst + " / " + name
        size_str = size.replace(",", ".")
        parsed[item_key] = {"type": stype, "size": size_str}
    
    data = parsed.get(item)
    if data == None:
        return {"changed": False, "msg": "no such storagepool: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    size_str_val = data.get("size", "0")
    size_mb = float(size_str_val) if size_str_val.replace(".", "", 1).lstrip("-").isdigit() else 0.0
    size_bytes = int(size_mb * 1024 * 1024)
    
    if size_bytes >= 1024 * 1024 * 1024 * 1024:
        size_str = "%f TB" % (size_bytes / (1024.0 * 1024 * 1024 * 1024))
    elif size_bytes >= 1024 * 1024 * 1024:
        size_str = "%f GB" % (size_bytes / (1024.0 * 1024 * 1024))
    else:
        size_str = "%f MB" % (size_bytes / (1024.0 * 1024))
    
    return {
        "changed": False,
        "msg": "Used size: %s, Type: %s" % (size_str, data.get("type", "")),
        "data": {
            "state": "OK",
            "metrics": {"used_space": size_bytes},
            "details": ""
        }
    }