def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/var/lib/check-mk-agent/local/hp_msa_volume"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 volumes",
                    "data": {"discovery": []}}
        
        volumes = {}
        for line in res.stdout.splitlines():
            parts = line.split()
            if len(parts) < 4:
                continue
            if parts[0] == "volumes" and parts[2] == "volume-name":
                vol_id = parts[1]
                vol_name = parts[3]
                volumes[vol_name] = {"durable-id": vol_id}
            elif parts[0] == "volumes" and parts[2] == "durable-id":
                vol_id = parts[1]
                vol_durable = parts[3]
                volumes[vol_id] = {"durable-id": vol_durable}
        
        items = [{"item": vol_name, "params": {}, "metrics": ["health"]} 
                 for vol_name in volumes.keys()]
        
        return {"changed": False, "msg": "discovered %d volumes" % len(items),
                "data": {"discovery": items}}
    
    item = params.get("item", "")
    res = ctx.run(["cat", "/var/lib/check-mk-agent/local/hp_msa_volume"], mutates=False)
    
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no volume data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    vol_data = {}
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        vol_id = parts[1]
        key = parts[2]
        value = " ".join(parts[3:])
        
        if parts[0] == "volumes":
            if vol_id not in vol_data:
                vol_data[vol_id] = {}
            vol_data[vol_id][key] = value
    
    matching_vol = None
    for vol_id, data in vol_data.items():
        if data.get("volume-name") == item or data.get("durable-id") == item:
            matching_vol = data
            break
    
    if matching_vol == None:
        return {"changed": False, "msg": "volume not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    health = matching_vol.get("health", "UNKNOWN")
    health_numeric = matching_vol.get("health-numeric", "-1")
    
    state = "UNKNOWN"
    if health_numeric == "0":
        state = "OK"
    elif health_numeric == "1":
        state = "WARN"
    elif health_numeric == "2" or health_numeric == "3":
        state = "CRIT"
    elif health == "OK":
        state = "OK"
    elif health in ["Degraded", "Warning"]:
        state = "WARN"
    elif health in ["Failed", "Critical", "Error"]:
        state = "CRIT"
    
    size_numeric = matching_vol.get("total-size-numeric", "0")
    alloc_numeric = matching_vol.get("allocated-size-numeric", "0")
    
    size_mb = 0
    alloc_mb = 0
    avail_mb = 0
    if size_numeric.isdigit() and alloc_numeric.isdigit():
        size_bytes = int(size_numeric) * 512
        alloc_bytes = int(alloc_numeric) * 512
        size_mb = size_bytes // 1024 // 1024
        alloc_mb = alloc_bytes // 1024 // 1024
        avail_mb = size_mb - alloc_mb
    
    virtual_disk = matching_vol.get("virtual-disk-name", "")
    raidtype = matching_vol.get("raidtype", "")
    
    msg_parts = []
    if virtual_disk:
        msg_parts.append(virtual_disk)
    if raidtype:
        msg_parts.append(raidtype)
    if health_numeric != "-1":
        health_display = health if health != "UNKNOWN" else "Unknown"
        msg_parts.append("Health: %s" % health_display)
    
    msg = " ".join(msg_parts) if msg_parts else item
    
    health_val = 0 if state == "OK" else (1 if state == "WARN" else 2)
    metrics = {"health": health_val}
    if size_mb > 0:
        metrics["size_mb"] = size_mb
        metrics["used_mb"] = alloc_mb
        metrics["avail_mb"] = avail_mb
        metrics["used_percent"] = (alloc_mb * 100) // size_mb if size_mb > 0 else 0
    
    details = matching_vol.get("health-reason", "")
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": details,
        },
    }