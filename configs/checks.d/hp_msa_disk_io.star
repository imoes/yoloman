def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, "1.3.6.1.4.1.232.14.2.2.1"
        ], mutates=False)
        lines = res.stdout.splitlines()
        items = {}
        for line in lines:
            line = line.strip()
            if not line:
                continue
            parts = line.split(" = ")
            if len(parts) != 2:
                continue
            oid = parts[0].strip()
            value_str = parts[1].strip()
            val_parts = value_str.split(": ")
            if len(val_parts) < 2:
                continue
            
            oid_parts = oid.split(".")
            idx_str = oid_parts[-2] if len(oid_parts) > 2 else ""
            if not idx_str.isdigit():
                continue
            idx = int(idx_str)
            
            val_str = val_parts[1]
            if not val_str.replace("-", "").isdigit():
                continue
            val = int(val_str)
            
            if idx not in items:
                items[idx] = {}
            suffix = oid.rsplit(".", 1)[-1]
            if suffix == "1":
                items[idx]["name"] = val_parts[1]
            elif suffix == "15":
                items[idx]["read"] = float(val)
            elif suffix == "16":
                items[idx]["write"] = float(val)
        
        out = []
        for idx, disk in items.items():
            name = disk.get("name", "disk_" + str(idx))
            out.append({
                "item": name,
                "params": {
                    "read": "read",
                    "write": "write",
                    "average": "60",
                    "state": "0"
                },
                "metrics": ["read", "write"]
            })
        return {
            "changed": False,
            "msg": "discovered %d disks" % len(out),
            "data": {"discovery": out}
        }
    
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, "1.3.6.1.4.1.232.14.2.2.1"
    ], mutates=False)
    lines = res.stdout.splitlines()
    items = {}
    for line in lines:
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        value_str = parts[1].strip()
        val_parts = value_str.split(": ")
        if len(val_parts) < 2:
            continue
        
        oid_parts = oid.split(".")
        idx_str = oid_parts[-2] if len(oid_parts) > 2 else ""
        if not idx_str.isdigit():
            continue
        idx = int(idx_str)
        
        val_str = val_parts[1]
        if not val_str.replace("-", "").isdigit():
            continue
        val = int(val_str)
        
        if idx not in items:
            items[idx] = {"name": "", "read": 0.0, "write": 0.0}
        suffix = oid.rsplit(".", 1)[-1]
        if suffix == "1":
            items[idx]["name"] = val_parts[1]
        elif suffix == "15":
            items[idx]["read"] = float(val)
        elif suffix == "16":
            items[idx]["write"] = float(val)
    
    found = False
    disk_data = None
    if item == "SUMMARY":
        found = True
        disk_data = {"name": "SUMMARY", "read": 0.0, "write": 0.0}
        for d in items.values():
            disk_data["read"] = disk_data["read"] + d.get("read", 0.0)
            disk_data["write"] = disk_data["write"] + d.get("write", 0.0)
    else:
        for idx, disk in items.items():
            name = disk.get("name", "")
            if name == item:
                disk_data = disk
                found = True
                break
    
    if not found or disk_data == None:
        return {
            "changed": False,
            "msg": "disk not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    read_val = disk_data.get("read", 0.0)
    write_val = disk_data.get("write", 0.0)
    
    warn = params.get("warn", 80.0)
    crit = params.get("crit", 90.0)
    warn_lower = params.get("warn_lower", None)
    crit_lower = params.get("crit_lower", None)
    
    state = "OK"
    if crit_lower != None and read_val <= crit_lower:
        state = "CRIT"
    elif warn_lower != None and read_val <= warn_lower:
        state = "WARN"
    elif read_val >= crit:
        state = "CRIT"
    elif read_val >= warn:
        state = "WARN"
    elif crit_lower != None and write_val <= crit_lower:
        state = "CRIT"
    elif warn_lower != None and write_val <= warn_lower:
        state = "WARN"
    elif write_val >= crit:
        state = "CRIT"
    elif write_val >= warn:
        state = "WARN"
    
    msg_parts = []
    if disk_data.get("name", "") != "":
        msg_parts.append(disk_data["name"])
    msg_parts.append("read: %f MB/s" % read_val)
    msg_parts.append("write: %f MB/s" % write_val)
    
    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": state,
            "metrics": {"read": read_val, "write": write_val},
            "details": ""
        }
    }