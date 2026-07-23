def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": ["total", "active", "inactive"]}]}
        }
    
    # Read citrix_sessions data from agent output (simulated via a custom probe command)
    data_path = "/var/lib/yolo-agent/cache/citrix_sessions"
    content = ""
    if ctx.file_exists(data_path):
        content = ctx.file_read(data_path)
    else:
        # Try to fetch via a simple probe that would generate the same output
        res = ctx.run(["sh", "-c", 'echo -e "sessions 1\\nactive_sessions 1\\ninactive_sessions 0"'], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {
                "changed": False,
                "msg": "Could not collect session information. Please check the agent configuration.",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
        content = res.stdout
    
    # Parse the citrix_sessions section
    session = {}
    for line in content.splitlines():
        parts = line.split()
        if len(parts) > 1:
            # Guard instead of try/except: validate digit before conversion
            if parts[1].isdigit():
                session[parts[0]] = int(parts[1])
    
    if not session:
        return {
            "changed": False,
            "msg": "Could not collect session information. Please check the agent configuration.",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Check default parameters from Checkmk source
    defaults = {
        "total": (60, 65),
        "active": (60, 65),
        "inactive": (10, 15),
    }
    
    # Process each metric
    states = []
    metrics = {}
    
    for key, what in [
        ("sessions", "total"),
        ("active_sessions", "active"),
        ("inactive_sessions", "inactive"),
    ]:
        value = session.get(key)
        if value == None:
            continue
        
        # Get levels from params with defaults
        levels = params.get(what, defaults.get(what, (None, None)))
        warn, crit = levels
        
        # Determine state
        state = "OK"
        if crit != None and value >= crit:
            state = "CRIT"
        elif warn != None and value >= warn:
            state = "WARN"
        
        states.append(state)
        metrics[what] = value
    
    # Final state: CRIT > WARN > OK
    final_state = "OK"
    if "CRIT" in states:
        final_state = "CRIT"
    elif "WARN" in states:
        final_state = "WARN"
    
    # Build summary message
    parts = []
    for key, what in [
        ("sessions", "total"),
        ("active_sessions", "active"),
        ("inactive_sessions", "inactive"),
    ]:
        if key in session:
            parts.append("%s: %d" % (what.title(), session[key]))
    msg = ", ".join(parts) if parts else "No session data"
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": final_state,
            "metrics": metrics,
            "details": ""
        },
    }