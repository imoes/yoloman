# Check: sap_hana_data_volume
# Source: cmk/plugins/sap_hana/agent_based/sap_hana_data_volume.py
# Reads SAP HANA data volume usage via hdbsql CLI tool

def _to_float(s):
    """Safely convert string to float, return 0 on failure."""
    if s == None or s == "":
        return 0
    # Check if it looks numeric (allow digits, ., and -)
    cleaned = s
    is_num = True
    has_digit = False
    for ch in cleaned:
        if ch.isdigit():
            has_digit = True
        elif ch == "." or ch == "-":
            pass
        else:
            is_num = False
            break
    if not is_num or not has_digit:
        return 0
    return float(cleaned)

def _discover_volumes(ctx, sid_instance):
    """Discover data volumes for a given SID:INSTANCE via hdbsql."""
    section = {}
    MB = 1024 * 1024
    
    # Query M_VOLUME_STATUS for volume info
    res = ctx.run([
        "hdbsql", "-t", "-i", sid_instance,
        "SELECT SERVICE_NAME, PATH, TOTAL_SIZE, USED_SIZE FROM M_VOLUME_STATUS"
    ], mutates=False)
    if res.rc != 0:
        return section
    
    lines = res.stdout.splitlines()
    for line in lines:
        parts = line.split()
        if len(parts) < 4:
            continue
        
        service = parts[0]
        path = parts[1]
        total = _to_float(parts[2])
        used = _to_float(parts[3])
        
        key = "%s - %s %s" % (sid_instance, service, path)
        inst = section.setdefault(key, {"service": service, "path": path})
        inst["size"] = total / MB
        inst["used"] = used / MB
    
    return section

def _check_volume(ctx, item, params, section):
    """Check a single data volume item."""
    item_data = section.get(item)
    if not item_data:
        return {"state": "UNKNOWN", "msg": "no data volume found for item: " + item, "metrics": {}, "details": ""}
    
    size = item_data["size"]
    used = item_data["used"]
    avail = size - used
    
    if size <= 0:
        pct = 0
    else:
        pct = (used / size) * 100
    
    warn = params.get("warn", 80)
    crit = params.get("crit", 90)
    
    if pct >= crit:
        state = "CRIT"
    elif pct >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    msg_parts = ["%s: %f%% used (%f MB of %f MB)" % (item, pct, used, size - used, size)]
    
    service = item_data.get("service")
    if service:
        msg_parts.append("Service: %s" % service)
    path = item_data.get("path")
    if path:
        msg_parts.append("Path: %s" % path)
    
    return {
        "state": state,
        "msg": ", ".join(msg_parts),
        "metrics": {"used_percent": pct, "size": size, "used": used, "avail": avail},
        "details": ""
    }

def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: find all SAP HANA instances and their volumes
        hdbsql_res = ctx.run(["which", "hdbsql"], mutates=False)
        if hdbsql_res.rc != 0:
            return {"changed": False, "msg": "no SAP HANA found (hdbsql not installed)", "data": {"discovery": []}}
        
        # Find SAP HANA instances
        inst_res = ctx.run([
            "hdbsql", "-t",
            "SELECT INSTANCE_NAME FROM M_DATABASES"
        ], mutates=False)
        
        instances = []
        if inst_res.rc == 0:
            for line in inst_res.stdout.splitlines():
                line = line.strip()
                if line and line != "INSTANCE_NAME":
                    instances.append(line)
        
        # If no SID:INSTANCE found, try default
        if not instances:
            instances = ["00"]
        
        discovery = []
        for sid_instance in instances:
            section = _discover_volumes(ctx, sid_instance)
            for item in section:
                discovery.append({
                    "item": item,
                    "params": {"warn": 80, "crit": 90},
                    "metrics": ["used_percent", "size", "used", "avail"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d SAP HANA data volumes" % len(discovery),
            "data": {"discovery": discovery}
        }
    
    # Check mode: check one specific item
    item = params.get("item", "")
    
    # Determine which instance this item belongs to
    sid_instance = "00"
    if ":" in item:
        sid_instance = item.split(":")[0]
    
    section = _discover_volumes(ctx, sid_instance)
    
    if not section:
        return {
            "changed": False,
            "msg": "no SAP HANA data volume found for item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "no SAP HANA data volume found for item: " + item}
        }
    
    result = _check_volume(ctx, item, params, section)
    return {
        "changed": False,
        "msg": result["msg"],
        "data": {"state": result["state"], "metrics": result["metrics"], "details": result["details"]}
    }