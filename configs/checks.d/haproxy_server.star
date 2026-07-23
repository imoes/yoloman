
# HAProxy status enums (matching Checkmk's library)
HAProxyFrontendStatus = {
    "OPEN": "OPEN",
    "STOP": "STOP",
}

HAProxyServerStatus = {
    "UP": "UP",
    "DOWN": "DOWN",
    "NOLB": "NOLB",
    "MAINT": "MAINT",
    "MAINT_RES": "MAINT (resolution)",
    "MAINT_VIA": "MAINT (via)",
    "DRAIN": "DRAIN",
    "NO_CHECK": "no check",
}

# Default states per status (OK=0, WARN=1, CRIT=2, UNKNOWN=3)
DEFAULT_FRONTEND_STATES = {
    "OPEN": 0,
    "STOP": 2,
}

DEFAULT_SERVER_STATES = {
    "UP": 0,
    "DOWN": 2,
    "NOLB": 2,
    "MAINT": 2,
    "MAINT_VIA": 1,
    "MAINT_RES": 1,
    "DRAIN": 2,
    "NO_CHECK": 2,
}


def _parse_status(status_str, enum_dict, default_states):
    """Convert string status to enum key, return None if invalid."""
    for k in enum_dict.keys():
        if status_str == k:
            return k
    return None


def _get_state_from_params(status_key, params, default_states):
    """Return State code from params or default_states."""
    if status_key == None:
        return 3  # UNKNOWN
    
    if params.get(status_key) != None:
        return int(params.get(status_key))
    elif status_key in default_states:
        return int(default_states[status_key])
    else:
        return 1  # WARN for unknown status


def main(ctx, params):
    if params.get("_discover"):
        # Discovery: gather HAProxy socket data via stats socket
        socket_path = params.get("socket", "/var/run/haproxy.sock")
        cmd = ["socat", "-u", socket_path, "STDOUT"]
        res = ctx.run(cmd, mutates=False)
        if res.rc != 0 or not res.stdout:
            # No HAProxy stats available - return empty discovery
            return {"changed": False, "msg": "no HAProxy data available", 
                    "data": {"discovery": []}}
        
        # Parse CSV stats output (same format as Checkmk agent plugin expects)
        lines = res.stdout.splitlines()
        if len(lines) == 0:
            return {"changed": False, "msg": "no HAProxy data available", 
                    "data": {"discovery": []}}
        
        # First line is header; skip it
        header = lines[0].split(',')
        if len(header) <= 32:
            return {"changed": False, "msg": "invalid HAProxy stats format", 
                    "data": {"discovery": []}}
        
        # Find column indices
        type_col = 32
        name_col = 0
        frontend_name_col = 1
        
        # Discover backends (type '2') and servers (type '3')
        discovered = []
        for line in lines[1:]:
            fields = line.split(',')
            if len(fields) <= type_col:
                continue
            typ = fields[type_col].strip()
            if typ == '2':  # backend
                item = fields[name_col].strip()
                discovered.append({
                    "item": item,
                    "params": {},
                    "metrics": ["active_backends", "session_rate"]
                })
            elif typ == '3':  # server
                item = fields[name_col].strip() + "/" + fields[frontend_name_col].strip()
                discovered.append({
                    "item": item,
                    "params": {},
                    "metrics": ["active_backends", "session_rate"]
                })
        
        return {"changed": False, "msg": "discovered %d HAProxy items" % len(discovered),
                "data": {"discovery": discovered}}

    # Check mode
    item = params.get("item", "")
    socket_path = params.get("socket", "/var/run/haproxy.sock")
    cmd = ["socat", "-u", socket_path, "STDOUT"]
    res = ctx.run(cmd, mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no HAProxy data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse CSV stats
    lines = res.stdout.splitlines()
    if len(lines) <= 1:
        return {"changed": False, "msg": "no HAProxy data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    header = lines[0].split(',')
    type_col = 32
    name_col = 0
    frontend_name_col = 1
    status_col = 17
    stot_col = 7
    uptime_col = 23
    active_col = 19
    backup_col = 20
    layer_check_col = 36

    # Look for our item
    server_data = None
    for line in lines[1:]:
        fields = line.split(',')
        if len(fields) <= type_col:
            continue
        
        item_name = ""
        if fields[type_col].strip() == "2":  # backend
            item_name = fields[name_col].strip()
        elif fields[type_col].strip() == "3":  # server
            item_name = fields[name_col].strip() + "/" + fields[frontend_name_col].strip()
        
        if item_name == item:
            status_str = fields[status_col].strip()
            stot_str = fields[stot_col].strip()
            uptime_str = fields[uptime_col].strip() if len(fields) > uptime_col else ""
            active_str = fields[active_col].strip() if len(fields) > active_col else ""
            backup_str = fields[backup_col].strip() if len(fields) > backup_col else ""
            layer_check_str = fields[layer_check_col].strip() if len(fields) > layer_check_col else ""

            server_data = {
                "status": status_str,
                "stot": int(stot_str) if stot_str.isdigit() else None,
                "uptime": int(uptime_str) if uptime_str.isdigit() else None,
                "active": int(active_str) if active_str.isdigit() else None,
                "backup": int(backup_str) if backup_str.isdigit() else None,
                "layer_check": layer_check_str,
            }
            break

    if server_data == None:
        return {"changed": False, "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status = server_data["status"]
    status_key = _parse_status(status, HAProxyServerStatus, DEFAULT_SERVER_STATES)
    state_code = _get_state_from_params(status_key, params, DEFAULT_SERVER_STATES)
    state = "UNKNOWN" if state_code == 3 else ("OK" if state_code == 0 else ("WARN" if state_code == 1 else "CRIT"))
    
    summary_parts = []
    if status_key == None:
        summary_parts.append("Unknown status: " + status)
        state = "UNKNOWN"
    else:
        summary_parts.append("Status: " + HAProxyServerStatus.get(status_key, status))
    
    # Determine active/backup status
    if server_data["active"] != None:
        summary_parts.append("Active")
        if server_data["active"] > 0:
            # Active backends metric (only for backends)
            if server_data["active"] > 0 and status_key == "BACKEND":
                pass  # metric will be added below
    
    if server_data["active"] == None and server_data["backup"] != None and server_data["backup"] > 0:
        summary_parts.append("Backup")
    
    if server_data["active"] == None and server_data["backup"] == None:
        summary_parts.append("Neither active nor backup")
        if status_key != None:
            state = "CRIT"

    if server_data["layer_check"] != None and server_data["layer_check"] != "":
        summary_parts.append("Layer Check: " + server_data["layer_check"])

    if server_data["uptime"] != None:
        if status_key != None:
            state_str = HAProxyServerStatus.get(status_key, status)
        else:
            state_str = status
        summary_parts.append("%s since %ds" % (state_str, server_data["uptime"]))

    # Compute session rate (simplified - without value store persistence across calls)
    # We'll just report the raw stot as a counter; in real checkmk this would be rate-computed
    # Since we can't persist state, just report the stot value directly as a metric
    metrics = {}
    if server_data["stot"] != None:
        metrics["stot"] = server_data["stot"]
        summary_parts.append("Session rate: %d" % server_data["stot"])

    if server_data["active"] != None:
        metrics["active_backends"] = server_data["active"]
        summary_parts.append("Active backends: %d" % server_data["active"])

    msg = ", ".join(summary_parts)
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}