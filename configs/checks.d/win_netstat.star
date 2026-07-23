# win_netstat starlark check module
# Reads TCP/UDP connection state from netstat -an and counts connections
# matching optional filters (local_ip, local_port, remote_ip, remote_port, proto, state)

def main(ctx, params):
    # Discovery is disabled (discover_netstat_never), so only check mode runs
    # Gather TCP/UDP connections using netstat -an (works on Windows via cmd /c)
    res = ctx.run(["cmd", "/c", "netstat", "-an"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to run netstat: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse netstat output to connections list
    connections = []
    lines = res.stdout.splitlines()
    # Skip header lines (usually 2 for English, but we skip until we see TCP/UDP lines)
    i = 0
    while i < len(lines) and not (lines[i].startswith("TCP") or lines[i].startswith("UDP")):
        i += 1
    
    while i < len(lines):
        line = lines[i].strip()
        if not line:
            i += 1
            continue
        parts = line.split()
        if not parts:
            i += 1
            continue
        
        if parts[0] == "TCP":
            if len(parts) >= 4:
                proto = parts[0]
                local = parts[1]
                remote = parts[2]
                state = parts[3]
                connections.append({"proto": proto, "local": local, "remote": remote, "state": state})
        elif parts[0] == "UDP":
            if len(parts) >= 3:
                proto = parts[0]
                local = parts[1]
                remote = parts[2]
                # UDP has no state in netstat output; Checkmk maps to LISTENING
                connections.append({"proto": proto, "local": local, "remote": remote, "state": "LISTENING"})
        i += 1
    
    # Extract params with defaults (matching check_default_parameters)
    min_states = params.get("min_states", ("no_levels", None))
    max_states = params.get("max_states", ("no_levels", None))
    
    # Extract filter params if present
    local_ip = params.get("local_ip")
    local_port = params.get("local_port")
    remote_ip = params.get("remote_ip")
    remote_port = params.get("remote_port")
    proto_filter = params.get("proto")
    state_filter = params.get("state")
    
    # Count matching connections
    def split_ip(ip_str):
        # Handle IPv6 addresses: rsplit(':', 1) for port
        # But IPv6 has multiple colons; use rightmost colon for port separator
        if ":" in ip_str:
            idx = ip_str.rfind(":")
            return (ip_str[:idx], ip_str[idx+1:])
        return (ip_str, "")
    
    count = 0
    for c in connections:
        # Apply filters if specified (match only if filter equals current value)
        if proto_filter != None and c["proto"] != proto_filter:
            continue
        if state_filter != None and c["state"] != state_filter:
            continue
        
        # Parse local and remote
        l_ip, l_port = split_ip(c["local"])
        r_ip, r_port = split_ip(c["remote"])
        
        if local_ip != None and l_ip != local_ip:
            continue
        if local_port != None and l_port != local_port:
            continue
        if remote_ip != None and r_ip != remote_ip:
            continue
        if remote_port != None and r_port != remote_port:
            continue
        
        count += 1
    
    # Apply levels
    state = "OK"
    details = ""
    
    # Lower level (min_states)
    if min_states[0] != "no_levels":
        min_val = min_states[1]
        if count <= min_val:
            state = "CRIT"
            details = "below minimum threshold"
    
    # Upper level (max_states)
    if max_states[0] != "no_levels":
        max_val = max_states[1]
        if count >= max_val:
            state = "CRIT" if state == "OK" else "CRIT"
            details = "above maximum threshold" if not details else details + ", above maximum threshold"
    
    # Build message
    msg = "%d connections" % count
    if details:
        msg += ", " + details
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"connections": count},
            "details": "",
        },
    }