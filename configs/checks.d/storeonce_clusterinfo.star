def main(ctx, params):
    if params.get("_discover"):
        return discover(ctx, params)
    return check(ctx, params)

# STATE_MAP for StoreOnce health levels: 0=OK, 1=WARN, 2=CRIT
STATE_MAP = {
    "0": "OK",
    "1": "WARN",
    "2": "CRIT",
}

# df.FILESYSTEM_DEFAULT_PARAMS default thresholds
SPACE_DEFAULT_WARN = 80
SPACE_DEFAULT_CRIT = 90

# uptime default thresholds
UPTIME_DEFAULT_WARN = [60, None]
UPTIME_DEFAULT_CRIT = [90, None]

# Mapping from storeav output keys to section keys
STOREAV_TO_SECTION = {
    "Appliance Name": "Appliance Name",
    "Network Name": "Network Name",
    "Serial Number": "Serial Number",
    "Software Version": "Software Version",
    "Product Class": "Product Class",
    "Total Capacity": "Total Capacity",
    "Free Space": "Free Space",
    "User Data Stored": "User Data Stored",
    "Size On Disk": "Size On Disk",
    "Dedupe Ratio": "Dedupe Ratio",
    "Cluster Health Level": "Cluster Health Level",
    "Cluster Health": "Cluster Health",
    "Cluster Status": "Cluster Status",
    "Replication Health Level": "Replication Health Level",
    "Replication Health": "Replication Health",
    "Replication Status": "Replication Status",
    "Uptime Seconds": "Uptime Seconds",
    "sysContact": "sysContact",
    "sysLocation": "sysLocation",
    "isMixedCluster": "isMixedCluster",
}

def read_clusterinfo(ctx):
    # Check for StoreOnce CLI tools first
    av_res = ctx.run(["storeav", "show", "-l"], mutates=False)
    if av_res.rc == 127:
        # Not installed
        return None
    if av_res.rc != 0:
        return None
    # Parse the storeav output into key-value pairs
    data = {}
    for line in av_res.stdout.splitlines():
        line = line.strip()
        if not line or ":" not in line:
            continue
        parts = line.split(":", 1)
        if len(parts) == 2:
            key = parts[0].strip()
            value = parts[1].strip()
            section_key = STOREAV_TO_SECTION.get(key, key)
            data[section_key] = value
    return data

def discover(ctx, params):
    data = read_clusterinfo(ctx)
    if data == None:
        return {"changed": False, "msg": "no StoreOnce system found", "data": {"discovery": []}}
    discovery = []
    # General appliance info check
    if "Product Class" in data:
        discovery.append({"item": data.get("Product Class", ""), "params": {}, "metrics": []})
    # Cluster/Appliance status check
    if "Cluster Health" in data:
        discovery.append({"item": "", "params": {}, "metrics": []})
    # Space check
    if "Total Capacity" in data:
        discovery.append({"item": "Total Capacity", "params": {"warn": SPACE_DEFAULT_WARN, "crit": SPACE_DEFAULT_CRIT}, "metrics": ["used_percent"]})
    # Uptime check
    if "Uptime Seconds" in data:
        discovery.append({"item": "", "params": {"warn": UPTIME_DEFAULT_WARN, "crit": UPTIME_DEFAULT_CRIT}, "metrics": ["uptime"]})
    return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery}}

def check(ctx, params):
    item = params.get("item", "")
    check_name = params.get("_check_name", "storeonce_clusterinfo")
    data = read_clusterinfo(ctx)
    if data == None:
        return {"changed": False, "msg": "no StoreOnce system found", "data": {"state": "UNKNOWN", "metrics": {}, "details": "StoreOnce CLI not available"}}
    if check_name == "storeonce_clusterinfo":
        return check_general(ctx, params, data)
    elif check_name == "storeonce_clusterinfo_cluster":
        return check_cluster(ctx, params, data)
    elif check_name == "storeonce_clusterinfo_space":
        return check_space(ctx, params, data)
    elif check_name == "storeonce_clusterinfo_uptime":
        return check_uptime(ctx, params, data)
    return {"changed": False, "msg": "unknown check", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

def check_general(ctx, params, data):
    if "Appliance Name" not in data:
        return {"changed": False, "msg": "missing appliance data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    msg_parts = []
    state = "OK"
    if "Appliance Name" in data:
        msg_parts.append("Name: %s" % data["Appliance Name"])
    if "Serial Number" in data:
        msg_parts.append("Serial Number: %s" % data["Serial Number"])
    if "Software Version" in data:
        msg_parts.append("Version: %s" % data["Software Version"])
    details = "\n".join(msg_parts)
    return {"changed": False, "msg": "; ".join(msg_parts), "data": {"state": state, "metrics": {}, "details": details}}

def check_cluster(ctx, params, data):
    if "Cluster Health" not in data:
        return {"changed": False, "msg": "missing cluster data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    state = "OK"
    msg_parts = []
    if "Cluster Status" in data:
        msg_parts.append("Cluster Status: %s" % data["Cluster Status"])
    if "Replication Status" in data:
        msg_parts.append("Replication Status: %s" % data["Replication Status"])
    for component in ("Cluster Health", "Replication Health"):
        level_key = "%s Level" % component
        if level_key in data:
            level = data[level_key]
            comp_state = STATE_MAP.get(level, "UNKNOWN")
            msg_parts.append("%s: %s (Level %s)" % (component, data.get(component, ""), level))
            if comp_state == "CRIT":
                state = "CRIT"
            elif comp_state == "WARN" and state != "CRIT":
                state = "WARN"
    return {"changed": False, "msg": "; ".join(msg_parts), "data": {"state": state, "metrics": {}, "details": "\n".join(msg_parts)}}

def check_space(ctx, params, data):
    if "Total Capacity" not in data or "Free Space" not in data:
        return {"changed": False, "msg": "missing space data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    total = safe_float(data.get("Total Capacity"))
    free = safe_float(data.get("Free Space"))
    if total == None or free == None:
        return {"changed": False, "msg": "invalid capacity values", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    used = total - free
    if total > 0:
        used_percent = (used / total) * 100
    else:
        used_percent = 0
    warn = params.get("warn", SPACE_DEFAULT_WARN)
    crit = params.get("crit", SPACE_DEFAULT_CRIT)
    state = "CRIT" if used_percent >= crit else ("WARN" if used_percent >= warn else "OK")
    details = "Total: %f GB, Used: %f GB (%f%%), Free: %f GB" % (total, used, used_percent, free)
    return {"changed": False, "msg": "Used %f%%" % used_percent, "data": {"state": state, "metrics": {"used_percent": used_percent}, "details": details}}

def check_uptime(ctx, params, data):
    if "Uptime Seconds" not in data:
        return {"changed": False, "msg": "missing uptime data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    uptime_seconds = safe_float(data.get("Uptime Seconds"))
    if uptime_seconds == None:
        return {"changed": False, "msg": "invalid uptime value", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    uptime_days = uptime_seconds / 86400
    warn_params = params.get("warn", UPTIME_DEFAULT_WARN)
    crit_params = params.get("crit", UPTIME_DEFAULT_CRIT)
    warn_days = extract_threshold(warn_params)
    crit_days = extract_threshold(crit_params)
    state = "OK"
    if crit_days != None and uptime_days >= crit_days:
        state = "CRIT"
    elif warn_days != None and uptime_days >= warn_days:
        state = "WARN"
    details = "Uptime: %f days" % uptime_days
    return {"changed": False, "msg": details, "data": {"state": state, "metrics": {"uptime_days": uptime_days}, "details": details}}

def safe_float(val):
    if val == None:
        return None
    s = str(val)
    if len(s) == 0:
        return None
    # Simple float parse: check digits and decimal point
    valid_chars = "0123456789.-"
    all_valid = True
    for ch in s:
        if ch not in valid_chars:
            all_valid = False
            break
    if not all_valid:
        return None
    dot_count = 0
    minus_count = 0
    for ch in s:
        if ch == ".":
            dot_count = dot_count + 1
        if ch == "-":
            minus_count = minus_count + 1
    if dot_count > 1 or minus_count > 1:
        return None
    return float(s)

def extract_threshold(params_val):
    if params_val == None:
        return None
    if type(params_val) == "list":
        return params_val[0] if len(params_val) > 0 and params_val[0] != None else None
    return params_val