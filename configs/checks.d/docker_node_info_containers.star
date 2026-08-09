def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["docker", "info", "--format", "{{.ServerVersion}}|{{.Containers}}|{{.ContainersRunning}}|{{.ContainersPaused}}|{{.ContainersStopped}}|{{.Images}}|{{.Swarm.LocalNodeState}}|{{.Swarm.NodeID}}|{{.IndexServerAddress}}|{{range .Labels}}{{.}}{{end}}"], mutates=False)
        # If docker is not available or command fails, return empty discovery
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        
        # Always return one service for this check
        return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}
    
    # Check mode
    # Use JSON format to reliably parse docker info output
    res = ctx.run(["docker", "info", "--format", "{{json .}}"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "Docker daemon not accessible", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Guard: check stdout exists and is non-empty before parsing
    if not res.stdout or res.stdout.strip() == "":
        return {"changed": False, "msg": "Docker info output is empty", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    info = json.decode(res.stdout)
    
    # Build section dict from docker info
    section = {}
    section["ServerVersion"] = info.get("ServerVersion", "")
    section["Containers"] = info.get("Containers", 0)
    section["ContainersRunning"] = info.get("ContainersRunning", 0)
    section["ContainersPaused"] = info.get("ContainersPaused", 0)
    section["ContainersStopped"] = info.get("ContainersStopped", 0)
    section["Images"] = info.get("Images", 0)
    section["IndexServerAddress"] = info.get("IndexServerAddress", "")
    
    # Swarm info
    swarm = info.get("Swarm", {})
    if swarm:
        section["Swarm"] = swarm
    
    # Labels as list
    labels = info.get("Labels", [])
    if labels:
        section["Labels"] = labels
    
    # Check logic for containers count
    title = "containers"
    key = "Containers"
    count = section.get(key)
    if count == None:
        return {"changed": False, "msg": "Containers: count not present in agent output", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Apply levels (check uses check_levels_legacy_compatible)
    warn_upper = params.get("upper_levels", (None, None))
    crit_upper = params.get("upper_levels", (None, None))
    warn_lower = params.get("lower_levels", (None, None))
    crit_lower = params.get("lower_levels", (None, None))
    
    # For this check, levels are specified as tuples: (warn, crit)
    # Since default params is {}, and check expects (None, None) if not set,
    # we handle it simply by using None as defaults and letting the comparison logic work
    levels = (warn_upper[1] if type(warn_upper) == "list" and len(warn_upper) > 1 else None,
              crit_upper[1] if type(crit_upper) == "list" and len(crit_upper) > 1 else None)
    levels_lower = (warn_lower[0] if type(warn_lower) == "list" and len(warn_lower) > 0 else None,
                    crit_lower[0] if type(crit_lower) == "list" and len(crit_lower) > 0 else None)
    
    # Determine state based on levels
    state = "OK"
    if levels_lower:
        lower_crit = levels_lower[1]
        lower_warn = levels_lower[0]
        if lower_crit != None and count <= lower_crit:
            state = "CRIT"
        elif lower_warn != None and count <= lower_warn:
            state = "WARN"
    
    if state == "OK" and levels:
        upper_crit = levels[1]
        upper_warn = levels[0]
        if upper_crit != None and count >= upper_crit:
            state = "CRIT"
        elif upper_warn != None and count >= upper_warn:
            state = "WARN"
    
    summary = "Docker daemon running"
    if section.get("ServerVersion"):
        summary = summary + " version " + section["ServerVersion"]
    
    # Build metrics
    metrics = {
        "containers": section.get("Containers", 0),
        "running": section.get("ContainersRunning", 0),
        "paused": section.get("ContainersPaused", 0),
        "stopped": section.get("ContainersStopped", 0),
        "images": section.get("Images", 0),
    }
    
    return {"changed": False, "msg": summary, 
            "data": {"state": state, "metrics": metrics, "details": ""}}
