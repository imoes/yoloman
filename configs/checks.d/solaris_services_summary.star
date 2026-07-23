def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["svcs", "-a", "-H"], mutates=False)
        services = []
        for line in res.stdout.splitlines():
            parts = line.split()
            if len(parts) < 3:
                continue
            state, stime, fmri = parts[0], parts[1], parts[2]
            services.append({
                "item": "",
                "params": {},
                "metrics": []
            })
        return {
            "changed": False,
            "msg": "discovered SMF services summary",
            "data": {"discovery": services if services else []}
        }
    
    res = ctx.run(["svcs", "-a", "-H"], mutates=False)
    services = []
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        state, stime, fmri = parts[0], parts[1], parts[2]
        services.append({
            "state": state,
            "stime": stime,
            "fmri": fmri
        })
    
    count = len(services)
    services_by_state = {}
    for svc in services:
        state = svc["state"]
        if state not in services_by_state:
            services_by_state[state] = []
        services_by_state[state].append(svc)
    
    msg_parts = []
    msg_parts.append("%d service%s" % (count, "" if count == 1 else "s"))
    
    state_order = ["online", "disabled", "legacy_run", "maintenance"]
    result_state = "OK"
    
    for svc_state in state_order:
        if svc_state not in services_by_state:
            continue
        svc_names = services_by_state[svc_state]
        state_code = 0
        extra_info = ""
        if svc_state == "maintenance":
            maintenance_state = params.get("maintenance_state", 0)
            if maintenance_state != 0:
                extra_info = " (%s)" % ", ".join([s["fmri"] for s in svc_names])
                state_code = maintenance_state
        
        state_label = svc_state.replace("_", " ")
        msg_parts.append("%d %s%s" % (len(svc_names), state_label, extra_info))
        
        if state_code > 0 and result_state != "CRIT":
            if state_code == 2:
                result_state = "CRIT"
            elif state_code == 1:
                result_state = "WARN"
    
    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": result_state,
            "metrics": {"services_total": count},
            "details": ""
        }
    }