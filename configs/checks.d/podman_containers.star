def main(ctx, params):
    # Check if podman is installed
    podman_check = ctx.run(["podman", "--version"], mutates=False)
    if podman_check.rc == 127:
        if params.get("_discover"):
            return {"changed": False, "msg": "podman not installed", "data": {"discovery": []}}
        return {"changed": False, "msg": "podman not installed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    if podman_check.rc != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "podman not available", "data": {"discovery": []}}
        return {"changed": False, "msg": "podman not available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Discovery mode
    if params.get("_discover"):
        return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": [{"item": "", "params": {}, "metrics": ["podman_containers_dead_number", "podman_containers_exited_number", "podman_containers_exited_as_non_zero_number", "podman_containers_total_number", "podman_containers_running_number", "podman_containers_created_number", "podman_containers_paused_number", "podman_containers_stopped_number", "podman_containers_restarting_number", "podman_containers_removing_number"]}]}}
    
    # Check mode - get all containers
    res = ctx.run(["podman", "ps", "-a", "--format", "json"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to get podman containers: " + res.stderr, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    if not res.stdout.strip():
        return {"changed": False, "msg": "No containers found", "data": {"state": "OK", "metrics": {}, "details": ""}}
    
    containers = json.decode(res.stdout)
    
    # Count by state
    counts = {
        "total": 0,
        "running": 0,
        "created": 0,
        "paused": 0,
        "stopped": 0,
        "restarting": 0,
        "removing": 0,
        "dead": 0,
        "exited": 0,
        "exited_as_non_zero": 0,
    }
    
    for c in containers:
        state = c.get("State", "").lower()
        if state in counts:
            counts[state] += 1
        counts["total"] += 1
        exit_code = 0
        ec = c.get("ExitCode", 0)
        if type(ec) == "int":
            exit_code = ec
        elif type(ec) == "string":
            exit_code = int(ec) if ec and ec != "" else 0
        else:
            exit_code = int(ec) if ec != None else 0
        if exit_code != 0:
            counts["exited_as_non_zero"] += 1
    
    if counts["total"] == 0:
        return {"changed": False, "msg": "No containers found", "data": {"state": "OK", "metrics": {}, "details": ""}}
    
    # Apply levels for dead and exited_as_non_zero (notice_only)
    state = "OK"
    notice_parts = []
    
    # dead: levels_upper (1,1), notice_only
    dead_warn = 1
    dead_crit = 1
    dead_count = counts["dead"]
    if dead_count >= dead_crit:
        notice_parts.append("Dead containers: %d (CRIT)" % dead_count)
    elif dead_count >= dead_warn:
        notice_parts.append("Dead containers: %d (WARN)" % dead_count)
    
    # exited_as_non_zero: levels_upper (1,1), notice_only
    eanz_warn = 1
    eanz_crit = 1
    eanz_count = counts["exited_as_non_zero"]
    if eanz_count >= eanz_crit:
        notice_parts.append("Exited as non-zero: %d (CRIT)" % eanz_count)
    elif eanz_count >= eanz_warn:
        notice_parts.append("Exited as non-zero: %d (WARN)" % eanz_count)
    
    # Build metrics
    metrics = {}
    for state_name, count in counts.items():
        metrics["podman_containers_" + state_name + "_number"] = count
    
    summary = "Podman containers: %d total" % counts["total"]
    if notice_parts:
        state = "OK"  # notice_only keeps state OK
        summary = summary + ", " + ", ".join(notice_parts)
    
    return {"changed": False, "msg": summary, "data": {"state": state, "metrics": metrics, "details": ""}}