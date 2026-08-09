def _wildcard(value, reference):
    return value == None or value == reference

def _match_service_against_params(params, service):
    states = params.get("states", [("running", None, 0)])
    for t_state, t_start_type, mon_state in states:
        if _wildcard(t_state, service["state"]) and _wildcard(t_start_type, service["start_type"]):
            return mon_state
    return params.get("else", 2)

def main(ctx, params):
    is_windows = ctx.facts().get("os_family") == "windows"
    if not is_windows:
        # Not a Windows host — this check monitors Windows services.
        if params.get("_discover"):
            return {"changed": False, "msg": "not a Windows host", "data": {"discovery": []}}
        return {"changed": False, "msg": "no Windows services found on this host",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        mode = ctx.check_mode
        res = ctx.run(["powershell", "-NoProfile", "-Command",
                       "Get-Service | ForEach-Object { $_.Status + '/' + $_.StartType + ' ' + $_.DisplayName + ' ' + $_.Name }"],
                      mutates=False)
        if res.rc != 0 and not res.stdout:
            return {"changed": False, "msg": "failed to query Windows services",
                    "data": {"discovery": []}}
        services = []
        for line in res.stdout.splitlines():
            parts = line.split(" ", 2)
            if len(parts) < 3:
                continue
            status_field = parts[0]
            name = parts[1]
            display = parts[2]
            cur_state, start_type = status_field.split("/", 1) if "/" in status_field else (status_field, "unknown")
            services.append({"name": name, "state": cur_state, "start_type": start_type, "description": display})
        discovery = []
        for svc in services:
            discovery.append({"item": svc["name"],
                              "params": {"states": [("running", None, 0)], "else": 2, "additional_servicenames": []},
                              "metrics": []})
        return {"changed": False, "msg": "discovered %d services" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    res = ctx.run(["powershell", "-NoProfile", "-Command",
                   "Get-Service -Name '" + item.replace("'", "''") + "' | ForEach-Object { $_.Status + '/' + $_.StartType + ' ' + $_.DisplayName + ' ' + $_.Name }"],
                  mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "service not found: " + item,
                "data": {"state": params.get("else", 2), "metrics": {}, "details": ""}}

    lines = res.stdout.splitlines()
    if not lines:
        return {"changed": False, "msg": "service not found: " + item,
                "data": {"state": params.get("else", 2), "metrics": {}, "details": ""}}
    parts = lines[0].split(" ", 2)
    if len(parts) < 3:
        return {"changed": False, "msg": "malformed service output for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    status_field = parts[0]
    display = parts[1]
    name = parts[2]
    cur_state, start_type = status_field.split("/", 1) if "/" in status_field else (status_field, "unknown")
    svc = {"name": name, "state": cur_state, "start_type": start_type, "description": display}

    state_code = _match_service_against_params(params, svc)
    if state_code == 0:
        state = "OK"
    elif state_code == 1:
        state = "WARN"
    elif state_code == 2:
        state = "CRIT"
    else:
        state = "UNKNOWN"

    return {"changed": False,
            "msg": "%s: %s (start type is %s)" % (display, cur_state, start_type),
            "data": {"state": state, "metrics": {}, "details": ""}}