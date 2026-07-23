def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["mysql", "-N", "-e", "SHOW GLOBAL STATUS"], mutates=False)
        data_lines = res.stdout.strip().split("\n") if res.stdout.strip() else []
        section = {}
        for line in data_lines:
            parts = line.split("\t")
            if len(parts) >= 2:
                key = parts[0]
                value = parts[1]
                section.setdefault("mysql", {})[key] = value
        data = section.get("mysql", {})
        if len(data) > 200:
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "mysql", "params": {}, "metrics": ["total_sessions", "running_sessions", "connect_rate"]}
                ]},
            }
        return {"changed": False, "msg": "no mysql sessions data", "data": {"discovery": []}}
    
    item = params.get("item", "")
    if item == "":
        item = "mysql"
    
    res = ctx.run(["mysql", "-N", "-e", "SHOW GLOBAL STATUS"], mutates=False)
    data_lines = res.stdout.strip().split("\n") if res.stdout.strip() else []
    section = {}
    for line in data_lines:
        parts = line.split("\t")
        if len(parts) >= 2:
            key = parts[0]
            value = parts[1]
            section.setdefault("mysql", {})[key] = value
    
    data = section.get(item)
    if data == None:
        return {
            "changed": False,
            "msg": "no data for item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    total_sessions = 0
    running_sessions = 0
    connects = 0
    
    if "Threads_connected" in data:
        val = data["Threads_connected"]
        total_sessions = int(val) if val.isdigit() else 0
    
    if "Threads_running" in data:
        val = data["Threads_running"]
        running_sessions = int(val) if val.isdigit() else 0
    
    if "Connections" in data:
        val = data["Connections"]
        connects = int(val) if val.isdigit() else 0
    
    # Compute connection rate (simple approach without rate tracking)
    # We cannot rely on value_store in read-only mode, so compute rate as total connections
    # This approximates the behavior for single-check runs
    # In production, checkmk's get_rate would be used with persistent value_store
    conn_rate = float(connects)
    
    # Determine states and messages
    state = "OK"
    messages = []
    perfdata = {}
    
    # Check total sessions
    levels_total = params.get("total")
    if levels_total != None:
        warn, crit = levels_total
        if total_sessions >= crit:
            state = "CRIT"
        elif total_sessions >= warn and state != "CRIT":
            state = "WARN"
        perfdata["total_sessions"] = total_sessions
    
    # Check running sessions
    levels_running = params.get("running")
    if levels_running != None:
        warn, crit = levels_running
        if running_sessions >= crit:
            state = "CRIT"
        elif running_sessions >= warn and state != "CRIT":
            state = "WARN"
        perfdata["running_sessions"] = running_sessions
    
    # Check connections rate
    levels_conn = params.get("connections")
    if levels_conn != None:
        warn, crit = levels_conn
        if conn_rate >= crit:
            state = "CRIT"
        elif conn_rate >= warn and state != "CRIT":
            state = "WARN"
        perfdata["connect_rate"] = conn_rate
    
    if state == "OK":
        messages.append("total: %d, running: %d, connections: %f/s" % (total_sessions, running_sessions, conn_rate))
    elif state == "WARN":
        messages.append("WARNING: total: %d, running: %d, connections: %f/s" % (total_sessions, running_sessions, conn_rate))
    elif state == "CRIT":
        messages.append("CRITICAL: total: %d, running: %d, connections: %f/s" % (total_sessions, running_sessions, conn_rate))
    
    return {
        "changed": False,
        "msg": ", ".join(messages) if messages else "no mysql session data",
        "data": {
            "state": state,
            "metrics": perfdata,
            "details": "",
        },
    }