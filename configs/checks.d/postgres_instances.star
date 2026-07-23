def main(ctx, params):
    # Read the postgres_instances agent section by listing postgres processes
    res = ctx.run(["ps", "-eo", "pid,comm", "--no-headers"], mutates=False)
    lines = res.stdout.splitlines() if res.stdout else []
    
    instance_to_pid = {}
    all_pids = []
    
    for line in lines:
        parts = line.strip().split(None, 1)
        if len(parts) < 2:
            continue
        pid_str = parts[0]
        comm = parts[1]
        if not pid_str.isdigit():
            continue
        pid = int(pid_str)
        if "postgres" in comm.lower():
            instance_name = "postgres"
            instance_to_pid.setdefault(instance_name, pid)
            all_pids.append(pid)
    
    # Remove empty instance name if present
    instance_to_pid.pop("", None)
    
    # Handle discovery mode
    if params.get("_discover"):
        items = []
        for name in instance_to_pid:
            items.append({"item": name, "params": {}, "metrics": []})
        return {
            "changed": False,
            "msg": "discovered %d postgres instances" % len(items),
            "data": {"discovery": items},
        }
    
    # Normal check mode: check one item
    item = params.get("item", "")
    pid = instance_to_pid.get(item)
    
    # Get version info (not available from ps alone; we omit it per minimal requirement)
    version_info = None
    
    # Report status
    if pid != None:
        msg = "Status: running with PID %d" % pid
        state = "OK"
    else:
        msg = "Status: instance %s is not running or postgres DATADIR name is not identical with instance name" % item
        state = "CRIT"
    
    # Append version info
    if version_info != None:
        msg = "%s, Version: %s" % (msg, version_info)
    else:
        msg = "%s, Version: not found" % msg
    
    # Build details string
    details = ""
    if len(all_pids) > 0:
        pid_str = ""
        for i in range(len(all_pids)):
            if i > 0:
                pid_str = pid_str + ", "
            pid_str = pid_str + str(all_pids[i])
        details = "PIDs: " + pid_str
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {},
            "details": details,
        },
    }