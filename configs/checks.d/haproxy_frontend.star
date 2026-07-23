def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # We'll use the haproxy stats socket to get data
        # First check if socat is available
        res_socat = ctx.run(["which", "socat"])
        if res_socat.rc != 0:
            return {
                "changed": False,
                "msg": "socat not available for HAProxy stats",
                "data": {"discovery": []}
            }
        
        # Get HAProxy stats via socket
        haproxy_socket = params.get("haproxy_socket", "/run/haproxy.sock")
        socket_res = ctx.run(["socat", "stdio", haproxy_socket], mutates=False)
        
        if socket_res.rc != 0 or not socket_res.stdout.strip():
            return {
                "changed": False,
                "msg": "Failed to get HAProxy stats",
                "data": {"discovery": []}
            }
        
        # Parse HAProxy CSV output
        lines = socket_res.stdout.splitlines()
        header_line = None
        header_index = -1
        for i, line in enumerate(lines):
            if line.startswith("# pxname") or line.startswith("# frontend,svname"):
                header_line = line
                header_index = i
                break
        
        if header_line == None:
            return {
                "changed": False,
                "msg": "Invalid HAProxy stats format",
                "data": {"discovery": []}
            }
        
        # Parse header to get column indices
        header = header_line.lstrip("# ").strip().split(",")
        pxname_idx = -1
        svname_idx = -1
        status_idx = -1
        stot_idx = -1
        
        # Find indices safely
        for idx, col in enumerate(header):
            if col == "pxname":
                pxname_idx = idx
            elif col == "svname":
                svname_idx = idx
            elif col == "status":
                status_idx = idx
            elif col == "stot":
                stot_idx = idx
        
        # Check if all required indices found
        if pxname_idx == -1 or svname_idx == -1 or status_idx == -1 or stot_idx == -1:
            return {
                "changed": False,
                "msg": "Missing required columns in HAProxy stats",
                "data": {"discovery": []}
            }
        
        # Parse data lines
        frontends = []
        for line in lines[header_index + 1:]:
            if not line or line.startswith("#"):
                continue
            fields = line.split(",")
            if len(fields) <= max(pxname_idx, svname_idx, status_idx, stot_idx):
                continue
            
            pxname = fields[pxname_idx].strip()
            svname = fields[svname_idx].strip()
            
            # Only process frontends (svname == "FRONTEND")
            if svname == "FRONTEND":
                frontends.append(pxname)
        
        # Build discovery result
        discovery_items = []
        for name in frontends:
            # Default parameters as per Checkmk plugin
            discovery_items.append({
                "item": name,
                "params": {
                    "OPEN": 0,
                    "STOP": 2,
                },
                "metrics": ["session_rate"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d frontends" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }
    
    # Check mode - single frontend
    # Get frontend data
    res_socat = ctx.run(["which", "socat"])
    if res_socat.rc != 0:
        return {
            "changed": False,
            "msg": "socat not available for HAProxy stats",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    haproxy_socket = params.get("haproxy_socket", "/run/haproxy.sock")
    socket_res = ctx.run(["socat", "stdio", haproxy_socket], mutates=False)
    
    if socket_res.rc != 0 or not socket_res.stdout.strip():
        return {
            "changed": False,
            "msg": "Failed to get HAProxy stats",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse HAProxy CSV output
    lines = socket_res.stdout.splitlines()
    header_line = None
    header_index = -1
    for i, line in enumerate(lines):
        if line.startswith("# pxname") or line.startswith("# frontend,svname"):
            header_line = line
            header_index = i
            break
    
    if header_line == None:
        return {
            "changed": False,
            "msg": "Invalid HAProxy stats format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse header to get column indices
    header = header_line.lstrip("# ").strip().split(",")
    pxname_idx = -1
    svname_idx = -1
    status_idx = -1
    stot_idx = -1
    
    for idx, col in enumerate(header):
        if col == "pxname":
            pxname_idx = idx
        elif col == "svname":
            svname_idx = idx
        elif col == "status":
            status_idx = idx
        elif col == "stot":
            stot_idx = idx
    
    if pxname_idx == -1 or svname_idx == -1 or status_idx == -1 or stot_idx == -1:
        return {
            "changed": False,
            "msg": "Missing required columns in HAProxy stats",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse data lines
    item = params.get("item", "")
    frontend_data = None
    
    for line in lines[header_index + 1:]:
        if not line or line.startswith("#"):
            continue
        fields = line.split(",")
        if len(fields) <= max(pxname_idx, svname_idx, status_idx, stot_idx):
            continue
        
        pxname = fields[pxname_idx].strip()
        svname = fields[svname_idx].strip()
        
        if svname == "FRONTEND" and pxname == item:
            status = fields[status_idx].strip()
            stot_str = fields[stot_idx].strip()
            stot = int(stot_str) if stot_str.isdigit() else None
            frontend_data = {"status": status, "stot": stot}
            break
    
    if frontend_data == None:
        return {
            "changed": False,
            "msg": "Frontend not found: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Determine state based on status
    status = frontend_data["status"]
    default_params = {
        "OPEN": 0,
        "STOP": 2,
    }
    params_map = params.get("params", {})
    if not params_map:
        params_map = default_params
    
    if status == "OPEN":
        state = params_map.get("OPEN", default_params["OPEN"])
    elif status == "STOP":
        state = params_map.get("STOP", default_params["STOP"])
    else:
        state = 1  # WARN
    
    state_name = "OK" if state == 0 else ("WARN" if state == 1 else ("CRIT" if state == 2 else "UNKNOWN"))
    
    # Build summary message
    msg = "Status: %s" % status
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state_name,
            "metrics": {},
            "details": ""
        }
    }