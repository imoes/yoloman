def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.12124.2.2.52.1.2"
        ], mutates=False)
        disk_names = {}
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split(" = STRING: ")
            if len(parts) < 2:
                continue
            oid_val = parts[0].strip()
            disk_name = parts[1].strip().strip('"')
            # Extract instance index from OID (last numeric part after last dot)
            if oid_val.rfind(".") >= 0:
                idx = oid_val[oid_val.rfind(".") + 1:]
                if idx.isdigit():
                    disk_names[idx] = disk_name

        res_ops = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.12124.2.2.52.1.3"
        ], mutates=False)
        iops_map = {}
        for line in res_ops.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split(" = ")
            if len(parts) < 2:
                continue
            oid_val = parts[0].strip()
            val_str = parts[1].strip()
            if not val_str.startswith("INTEGER: "):
                continue
            if oid_val.rfind(".") >= 0:
                idx = oid_val[oid_val.rfind(".") + 1:]
                val_part = val_str.split(": ", 1)
                if len(val_part) == 2 and val_part[1].isdigit():
                    iops = int(val_part[1])
                    if idx in disk_names:
                        iops_map[disk_names[idx]] = iops

        discovery = []
        for item, iops in iops_map.items():
            discovery.append({
                "item": item,
                "params": {},
                "metrics": ["iops"]
            })

        return {
            "changed": False,
            "msg": "discovered %d disks" % len(discovery),
            "data": {"discovery": discovery}
        }

    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # First get disk index to name mapping
    res_names = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.12124.2.2.52.1.2"
    ], mutates=False)
    
    idx_to_disk = {}
    for line in res_names.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = STRING: ")
        if len(parts) < 2:
            continue
        oid_val = parts[0].strip()
        disk_name = parts[1].strip().strip('"')
        if oid_val.rfind(".") >= 0:
            idx = oid_val[oid_val.rfind(".") + 1:]
            if idx.isdigit():
                idx_to_disk[idx] = disk_name
    
    # Find the index corresponding to the requested item
    target_idx = ""
    found = False
    for idx, disk in idx_to_disk.items():
        if disk == item:
            target_idx = idx
            found = True
            break
    
    if not found:
        return {
            "changed": False,
            "msg": "disk not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Get iops value for the specific index
    res_ops = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.12124.2.2.52.1.3." + target_idx
    ], mutates=False)
    
    item_iops = None
    for line in res_ops.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ")
        if len(parts) < 2:
            continue
        val_str = parts[1].strip()
        if val_str.startswith("INTEGER: "):
            val_part = val_str.split(": ", 1)
            if len(val_part) == 2 and val_part[1].isdigit():
                item_iops = int(val_part[1])
                break
    
    if item_iops == None:
        return {
            "changed": False,
            "msg": "disk not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    state = "OK"
    msg = "Disk operations: %d/s" % item_iops

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"iops": item_iops},
            "details": ""
        }
    }
