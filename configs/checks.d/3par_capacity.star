def main(ctx, params):
    # Discovery mode: enumerate capacity items
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/diskinfo"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        
        data = json.decode(res.stdout)
        if type(data) != "dict":
            data = {}
        
        discovery = []
        for raw_name, raw_values in data.items():
            if type(raw_values) != "dict":
                continue
            name = raw_name.replace("Capacity", "")
            
            totalMiB = raw_values.get("totalMiB")
            freeMiB = raw_values.get("freeMiB")
            failedCapacityMiB = raw_values.get("failedCapacityMiB")
            
            if totalMiB == None or freeMiB == None or failedCapacityMiB == None:
                continue
            
            # Guard-based float conversion
            total_capacity = float(totalMiB) if str(totalMiB).replace(".", "").replace("-", "").isdigit() else 0.0
            free_capacity = float(freeMiB) if str(freeMiB).replace(".", "").replace("-", "").isdigit() else 0.0
            failed_capacity = float(failedCapacityMiB) if str(failedCapacityMiB).replace(".", "").replace("-", "").isdigit() else 0.0
            
            if total_capacity == 0:
                continue
            
            discovery.append({
                "item": name,
                "params": {
                    "levels": (80.0, 90.0),
                    "levels_low": (50.0, 20.0),
                    "magic_norm": 0.5,
                    "show_levels": "onwarning",
                    "show_reserved": False,
                    "show_timeleft": True,
                    "show_util": True,
                    "failed_capacity_levels": (0.0, 0.0),
                },
                "metrics": ["used_percent", "failed_percent"],
            })
        
        return {"changed": False, "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}
    
    # Check mode: inspect one item
    item = params.get("item", "")
    res = ctx.run(["cat", "/proc/diskinfo"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    data = json.decode(res.stdout)
    if type(data) != "dict":
        return {"changed": False, "msg": "no data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    disk = data.get(item)
    if disk == None or type(disk) != "dict":
        return {"changed": False, "msg": "item not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    totalMiB = disk.get("totalMiB")
    freeMiB = disk.get("freeMiB")
    failedCapacityMiB = disk.get("failedCapacityMiB")
    
    if totalMiB == None or freeMiB == None or failedCapacityMiB == None:
        return {"changed": False, "msg": "invalid data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Guard-based float conversion
    total_capacity = float(totalMiB) if str(totalMiB).replace(".", "").replace("-", "").isdigit() else 0.0
    free_capacity = float(freeMiB) if str(freeMiB).replace(".", "").replace("-", "").isdigit() else 0.0
    failed_capacity = float(failedCapacityMiB) if str(failedCapacityMiB).replace(".", "").replace("-", "").isdigit() else 0.0
    
    if total_capacity == 0:
        return {"changed": False, "msg": "no capacity data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Compute filesystem usage
    used_capacity = total_capacity - free_capacity
    used_percent = used_capacity * 100.0 / total_capacity
    
    # Extract thresholds from params (Checkmk defaults)
    warn, crit = params.get("levels", (80.0, 90.0))
    warn_low, crit_low = params.get("levels_low", (50.0, 20.0))
    
    # Grade filesystem usage (upper levels)
    state = "OK"
    if used_percent >= crit:
        state = "CRIT"
    elif used_percent >= warn:
        state = "WARN"
    elif used_percent <= crit_low:
        state = "CRIT"
    elif used_percent <= warn_low:
        state = "WARN"
    
    # Compute failed capacity percentage
    failed_percent = failed_capacity * 100.0 / total_capacity if total_capacity > 0 else 0.0
    failed_levels_warn, failed_levels_crit = params.get("failed_capacity_levels", (0.0, 0.0))
    
    if failed_percent >= failed_levels_crit or failed_percent >= failed_levels_warn:
        if failed_percent >= failed_levels_crit:
            state = "CRIT"
        elif state == "OK" or state == "WARN":
            if failed_percent >= failed_levels_warn:
                state = "WARN"
    
    # Build summary message
    total_bytes = total_capacity * 1024.0 * 1024.0
    failed_bytes = failed_capacity * 1024.0 * 1024.0
    
    # Format size using multiplication instead of **
    TiB = 1024.0 * 1024.0 * 1024.0 * 1024.0
    GiB = 1024.0 * 1024.0 * 1024.0
    MiB = 1024.0 * 1024.0
    
    if total_bytes >= TiB:
        size_str = "%f TB" % (total_bytes / TiB)
    elif total_bytes >= GiB:
        size_str = "%f GB" % (total_bytes / GiB)
    elif total_bytes >= MiB:
        size_str = "%f MB" % (total_bytes / MiB)
    else:
        size_str = "%f bytes" % total_bytes
    
    msg_parts = []
    msg_parts.append("Size: %s" % size_str)
    msg_parts.append("Used: %f%%" % used_percent)
    
    if failed_capacity > 0:
        if total_bytes >= TiB:
            failed_str = "%f TB" % (failed_bytes / TiB)
        elif total_bytes >= GiB:
            failed_str = "%f GB" % (failed_bytes / GiB)
        elif total_bytes >= MiB:
            failed_str = "%f MB" % (failed_bytes / MiB)
        else:
            failed_str = "%f bytes" % failed_bytes
        msg_parts.append("Failed: %f%% - %s of %s" % (failed_percent, failed_str, size_str))
    
    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": state,
            "metrics": {"used_percent": used_percent, "failed_percent": failed_percent},
            "details": "",
        },
    }