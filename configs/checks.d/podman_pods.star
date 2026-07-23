DEFAULT_PARAMS = {"dead": {"levels_upper": ("fixed", (1, 1))}}


def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["podman", "pods", "--format", "json"], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {
                "changed": False,
                "msg": "failed to list pods",
                "data": {"discovery": []}
            }
        
        pods = json.decode(res.stdout) if res.stdout else []
        
        if type(pods) != "list":
            return {
                "changed": False,
                "msg": "unexpected pod list format",
                "data": {"discovery": []}
            }
        
        # Count states
        counts = {
            "total": len(pods),
            "running": 0,
            "created": 0,
            "stopped": 0,
            "dead": 0,
            "exited": 0,
            "paused": 0,
            "degraded": 0
        }
        for i in range(len(pods)):
            pod = pods[i]
            if type(pod) == "dict":
                status = pod.get("Status", "").lower()
                if status in counts:
                    counts[status] = counts.get(status) + 1
        
        # Build discovery result for single-service check
        return {
            "changed": False,
            "msg": "discovered podman pods service",
            "data": {"discovery": [
                {
                    "item": "",
                    "params": DEFAULT_PARAMS,
                    "metrics": [
                        "podman_pods_total_number",
                        "podman_pods_running_number",
                        "podman_pods_created_number",
                        "podman_pods_stopped_number",
                        "podman_pods_dead_number",
                        "podman_pods_exited_number",
                        "podman_pods_paused_number",
                        "podman_pods_degraded_number",
                    ]
                }
            ]}
        }
    
    # Check mode
    res = ctx.run(["podman", "pods", "--format", "json"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "failed to list pods",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    pods = json.decode(res.stdout) if res.stdout else []
    
    if type(pods) != "list":
        return {
            "changed": False,
            "msg": "unexpected pod list format",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Count states
    counts = {
        "total": len(pods),
        "running": 0,
        "created": 0,
        "stopped": 0,
        "dead": 0,
        "exited": 0,
        "paused": 0,
        "degraded": 0
    }
    for i in range(len(pods)):
        pod = pods[i]
        if type(pod) == "dict":
            status = pod.get("Status", "").lower()
            if status in counts:
                counts[status] = counts.get(status) + 1
    
    # Determine worst state and build metrics
    state = "OK"
    details_parts = []
    
    for k in range(len(["total", "running", "created", "stopped", "dead", "exited", "paused", "degraded"])):
        states = ["total", "running", "created", "stopped", "dead", "exited", "paused", "degraded"]
        pod_state = states[k]
        if pod_state == "total":
            continue
        count = counts.get(pod_state, 0)
        state_params = params.get(pod_state, {})
        levels_upper = state_params.get("levels_upper")
        levels_lower = state_params.get("levels_lower")
        
        # Apply Checkmk-style level checking
        # For levels_upper: ("fixed", (warn, crit)) or None
        # For levels_lower: ("fixed", (warn, crit)) or None
        if levels_upper != None:
            if type(levels_upper) == "list" and len(levels_upper) == 2:
                if levels_upper[0] == "fixed":
                    upper_warn = levels_upper[1][0]
                    upper_crit = levels_upper[1][1]
                    if count >= upper_crit:
                        state = "CRIT"
                    elif count >= upper_warn and state != "CRIT":
                        state = "WARN"
        
        if levels_lower != None:
            if type(levels_lower) == "list" and len(levels_lower) == 2:
                if levels_lower[0] == "fixed":
                    lower_warn = levels_lower[1][0]
                    lower_crit = levels_lower[1][1]
                    if count <= lower_crit:
                        state = "CRIT"
                    elif count <= lower_warn and state != "CRIT":
                        state = "WARN"
        
        # Format description for this state
        details_parts.append("%s: %d" % (pod_state.capitalize(), count))
    
    if counts.get("total", 0) == 0:
        summary = "No pods found"
    else:
        summary = ", ".join(details_parts)
    
    metrics = {}
    for k in range(len(["total", "running", "created", "stopped", "dead", "exited", "paused", "degraded"])):
        states = ["total", "running", "created", "stopped", "dead", "exited", "paused", "degraded"]
        name = states[k]
        metrics["podman_pods_%s_number" % name] = counts.get(name, 0)
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }