def main(ctx, params):
    # Discovery mode: enumerate SMF services and yield one item per service
    if params.get("_discover"):
        res = ctx.run(["svcs", "-H", "-a"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to list services: " + res.stderr,
                    "data": {"discovery": []}}
        
        items = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.split(None, 2)  # Split into at most 3 fields
            if len(parts) < 3:
                continue
            state, stime, fmri = parts[0], parts[1], parts[2]
            items.append({
                "item": fmri,
                "params": {},
                "metrics": []
            })
        
        return {"changed": False, "msg": "discovered %d services" % len(items),
                "data": {"discovery": items}}
    
    # Check mode: verify one service item
    item = params.get("item", "")
    res = ctx.run(["svcs", "-H", item], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        # Service not found
        return {"changed": False,
                "msg": "Service not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse service status line
    parts = res.stdout.split(None, 2)
    if len(parts) < 3:
        return {"changed": False,
                "msg": "Unable to parse service status",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    svc_state, svc_stime, svc_name = parts[0], parts[1], parts[2]
    
    # Determine service state from configuration
    # Checkmk default: online->OK, disabled->CRIT, legacy_run->OK, maintenance->OK
    default_states = {
        "online": 0,
        "disabled": 2,
        "legacy_run": 0,
        "maintenance": 0,
    }
    
    # Apply explicit rule overrides if present in params
    states = params.get("states", [])
    check_state = default_states.get(svc_state, 2)  # Unknown states default to CRIT (2)
    
    for state_tuple in states:
        if len(state_tuple) >= 3 and state_tuple[0] == svc_state:
            # state_tuple format: (state, stime_match, result_state)
            rule_stime = state_tuple[1]
            if rule_stime == None:
                check_state = state_tuple[2]
            else:
                # stime format: check if restarted in last 24h (2 colons)
                has_changed = svc_stime.count(":") == 2
                if has_changed == rule_stime:
                    check_state = state_tuple[2]
                    break
    
    # Build message
    if svc_stime.count(":") == 2:
        info_stime = "Restarted in the last 24h (client's localtime: %s)" % svc_stime
    else:
        info_stime = "Started on %s" % svc_stime.replace("_", " ")
    
    state_map = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
    state = state_map.get(check_state, "UNKNOWN")
    
    return {
        "changed": False,
        "msg": "Status: %s, %s" % (svc_state, info_stime),
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }