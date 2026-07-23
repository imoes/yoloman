def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["redis-cli", "INFO", "server"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 instances",
                    "data": {"discovery": []}}
        
        item = "Redis"
        return {"changed": False, "msg": "discovered 1 instance",
                "data": {"discovery": [{"item": item, "params": {},
                                        "metrics": []}]}}
    
    item = params.get("item", "Redis")
    res = ctx.run(["redis-cli", "INFO", "server"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "could not retrieve Redis info: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    lines = res.stdout.splitlines()
    server_data = {}
    for line in lines:
        idx = line.find(":")
        if idx > 0:
            key = line[:idx].strip()
            value = line[idx+1:].strip()
            # Try int
            if value.isdigit() or (value.startswith("-") and value[1:].isdigit()):
                server_data[key] = int(value)
            elif value.replace(".","",1).isdigit() and value.count(".") < 2:
                server_data[key] = float(value)
            else:
                server_data[key] = value
    
    if not server_data:
        return {"changed": False, "msg": "no server data retrieved",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    state = "OK"
    details = []
    
    # Mode check
    server_mode = server_data.get("redis_mode")
    expected_mode = params.get("expected_mode")
    if server_mode != None:
        infotext = "Mode: %s" % server_mode.title()
        if expected_mode != None and expected_mode != server_mode:
            state = "WARN"
            infotext += " (expected: %s)" % expected_mode.title()
        details.append(infotext)
    
    # Uptime check
    uptime = server_data.get("uptime_in_seconds")
    if uptime != None:
        warn = params.get("warn")
        crit = params.get("crit")
        warn_sec = None
        crit_sec = None
        if warn != None and type(warn) == "float" or type(warn) == "int":
            warn_sec = int(float(warn) * 86400)
        if crit != None and type(crit) == "float" or type(crit) == "int":
            crit_sec = int(float(crit) * 86400)
        
        if crit_sec != None and uptime <= crit_sec:
            state = "CRIT"
            details.append("Uptime: %d s (critical: <= %d s)" % (uptime, crit_sec))
        elif warn_sec != None and uptime <= warn_sec:
            state = "WARN"
            details.append("Uptime: %d s (warning: <= %d s)" % (uptime, warn_sec))
        else:
            details.append("Uptime: %d s" % uptime)
    
    # Other info
    for key, infotext in [
        ("redis_version", "Version"),
        ("gcc_version", "GCC compiler version"),
        ("process_id", "PID"),
    ]:
        value = server_data.get(key)
        if value != None:
            details.append("%s: %s" % (infotext, str(value)))
    
    host = server_data.get("tcp_ip")
    if host == None:
        host = server_data.get("server")
    port = server_data.get("tcp_port")
    if host != None and port != None:
        details.append("IP: %s" % host)
        details.append("Port: %s" % port)
    elif host != None:
        details.append("IP: %s" % host)
    
    msg = "; ".join(details) if details else "Redis info retrieved"
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {}, "details": ""}}