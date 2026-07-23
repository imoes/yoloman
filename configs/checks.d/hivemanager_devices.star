# Checkmk check: hivemanager_devices
# Translated to Starlark for yolo-man agent (read-only)
# discovery: enumerate devices by hostname
# check: per-device metrics and thresholds

TOKEN_MULTIPLIER = [1, 60, 3600, 86400, 31536000]

def _parse_uptime(raw_uptime):
    if raw_uptime == "down":
        return None
    tokens = raw_uptime.split()
    if len(tokens) < 3:
        return None
    # reverse order excluding last token (assumed unit), take even indices
    vals = []
    for i in range(len(tokens) - 2, -1, -2):
        if tokens[i].isdigit():
            vals.append(int(tokens[i]))
        else:
            vals.append(0)
    # pad if needed (ensure at least 5 values)
    while len(vals) < 5:
        vals.append(0)
    total = 0
    for i in range(min(len(vals), len(TOKEN_MULTIPLIER))):
        total += TOKEN_MULTIPLIER[i] * vals[i]
    return total

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/var/lib/check-mk-agent/local/hivemanager_devices"], mutates=False)
        if res.rc != 0 or res.stdout == "":
            return {"changed": False, "msg": "discovered 0 devices", "data": {"discovery": []}}
        
        devices = {}
        for line in res.stdout.splitlines():
            if "::" not in line:
                continue
            entry = {}
            parts = line.split()
            # Each part should be key::value pairs separated by spaces
            for part in parts:
                if "::" in part:
                    key_val = part.split("::")
                    if len(key_val) == 2:
                        entry[key_val[0]] = key_val[1]
            if "hostName" in entry:
                devices[entry["hostName"]] = entry
        
        items = []
        for hostname in devices:
            items.append({
                "item": hostname,
                "params": {
                    "alert_on_loss": True,
                    "max_clients": [25, 50],
                    "crit_states": ["Critical"],
                    "warn_states": ["Maybe", "Major", "Minor"],
                },
                "metrics": ["client_count", "uptime"],
            })
        return {"changed": False, "msg": "discovered %d devices" % len(items),
                "data": {"discovery": items}}
    
    # Check mode
    item = params.get("item", "")
    res = ctx.run(["cat", "/var/lib/check-mk-agent/local/hivemanager_devices"], mutates=False)
    
    if res.rc != 0 or res.stdout == "":
        return {"changed": False, "msg": "device not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    section = {}
    for line in res.stdout.splitlines():
        if "::" not in line:
            continue
        entry = {}
        parts = line.split()
        for part in parts:
            if "::" in part:
                key_val = part.split("::")
                if len(key_val) == 2:
                    entry[key_val[0]] = key_val[1]
        if "hostName" in entry:
            section[entry["hostName"]] = entry
    
    if not item in section:
        return {"changed": False, "msg": "device not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    infos = section[item]
    
    warn_states = params.get("warn_states", ["Maybe", "Major", "Minor"])
    crit_states = params.get("crit_states", ["Critical"])
    alert_on_loss = params.get("alert_on_loss", True)
    max_clients = params.get("max_clients", [25, 50])
    warn_clients = max_clients[0]
    crit_clients = max_clients[1]
    max_uptime = params.get("max_uptime", None)
    
    # Check alarm state
    state = "OK"
    summary_parts = []
    
    if infos["alarm"] in crit_states:
        state = "CRIT"
        summary_parts.append("Alarm state: " + infos["alarm"])
    elif infos["alarm"] in warn_states:
        state = "WARN"
        summary_parts.append("Alarm state: " + infos["alarm"])
    
    # Connection lost check
    if alert_on_loss and infos["connection"] == "False":
        state = "CRIT"
        summary_parts.append("Connection lost")
    
    # Clients count
    num_clients = int(infos["clients"]) if infos["clients"].isdigit() else 0
    
    if num_clients >= crit_clients:
        if state != "CRIT":
            state = "CRIT"
        summary_parts.append("Clients: %d Warn/Crit at %d/%d" % (num_clients, warn_clients, crit_clients))
    elif num_clients >= warn_clients:
        if state == "OK":
            state = "WARN"
        summary_parts.append("Clients: %d Warn/Crit at %d/%d" % (num_clients, warn_clients, crit_clients))
    else:
        summary_parts.append("Clients: %d" % num_clients)
    
    # Uptime
    raw_uptime = infos.get("upTime", "down")
    uptime = _parse_uptime(raw_uptime)
    if uptime != None:
        uptime_summary = "Uptime: %d seconds" % uptime
        if max_uptime != None:
            warn_uptime = max_uptime[0] if type(max_uptime) == list else max_uptime
            crit_uptime = max_uptime[1] if type(max_uptime) == list else max_uptime
            
            # Upper levels -> CRIT if >= crit, WARN if >= warn
            if uptime >= crit_uptime:
                uptime_summary = "Uptime: %d seconds (warn/crit at %d/%d)" % (uptime, warn_uptime, crit_uptime)
                if state == "OK":
                    state = "WARN"
            elif uptime >= warn_uptime:
                uptime_summary = "Uptime: %d seconds (warn/crit at %d/%d)" % (uptime, warn_uptime, crit_uptime)
                if state == "OK":
                    state = "WARN"
        
        summary_parts.append(uptime_summary)
    else:
        summary_parts.append("Uptime: down")
    
    # Additional information
    additional_fields = [
        "eth0LLDPPort", "eth0LLDPSysName", "hive", "hiveOS", "hwmodel",
        "serialNumber", "nodeId", "location", "networkPolicy"
    ]
    extra_info = []
    for field in additional_fields:
        if field in infos and infos[field] != "-":
            extra_info.append("%s: %s" % (field, infos[field]))
    if extra_info:
        summary_parts.append(", ".join(extra_info))
    
    # Build summary
    summary = ", ".join(summary_parts)
    
    # Metrics
    metrics = {"client_count": num_clients}
    if uptime != None:
        metrics["uptime"] = uptime
    
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": metrics, "details": ""}}