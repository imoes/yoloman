def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    switch_state_names = {
        "1": "waiting",
        "2": "progressing",
        "3": "added",
        "4": "ready",
        "5": "sdmMismatch",
        "6": "verMismatch",
        "7": "featureMismatch",
        "8": "newMasterInit",
        "9": "provisioned",
        "10": "invalid",
        "11": "removed",
    }
    switch_role_names = {
        "1": "master",
        "2": "member",
        "3": "notMember",
        "4": "standby",
    }
    switch_state_descriptions = {
        "waiting": "Waiting for other switches to come online",
        "progressing": "Master election or mismatch checks in progress",
        "added": "Added to stack",
        "ready": "Ready",
        "sdmMismatch": "SDM template mismatch",
        "verMismatch": "OS version mismatch",
        "featureMismatch": "Configured feature mismatch",
        "newMasterInit": "Waiting for new master initialization",
        "provisioned": "Not an active member of the stack",
        "invalid": "State machine in invalid state",
        "removed": "Removed from stack",
    }

    def snmpwalk_oid(oid):
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid], mutates=False)
        if res.rc == 127:
            return None
        if res.rc != 0 or not res.stdout:
            return []
        lines = []
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) == 2:
                lines.append((parts[0], parts[1]))
        return lines

    base_oid = ".1.3.6.1.4.1.9.9.500.1.2.1.1"
    col_num = base_oid + ".1"
    col_role = base_oid + ".3"
    col_state = base_oid + ".6"

    if params.get("_discover"):
        state_data = snmpwalk_oid(col_state)
        if state_data == None:
            return {"changed": False, "msg": "snmp not available", "data": {"discovery": []}}
        if not state_data:
            return {"changed": False, "msg": "no cisco stack found", "data": {"discovery": []}}
        discovery = []
        seen = {}
        for oid, val in state_data:
            idx = oid[len(col_state) + 1:]
            seen[idx] = True
        for idx in sorted(seen.keys()):
            discovery.append({
                "item": idx,
                "params": {},
                "metrics": ["state", "role"],
            })
        return {
            "changed": False,
            "msg": "discovered %d stack switches" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    state_data = snmpwalk_oid(col_state)
    if state_data == None:
        return {
            "changed": False,
            "msg": "snmp not available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    switch_state = None
    switch_role = None
    for oid, val in state_data:
        idx = oid[len(col_state) + 1:]
        if idx == item:
            switch_state = val

    if switch_state == None:
        return {
            "changed": False,
            "msg": "no such switch in stack: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    role_data = snmpwalk_oid(col_role)
    if role_data:
        for oid, val in role_data:
            idx = oid[len(col_role) + 1:]
            if idx == item:
                switch_role = val

    state_name = switch_state_names.get(switch_state, "unknown")
    role_name = switch_role_names.get(switch_role, "unknown")

    default_levels = {
        "waiting": 0,
        "progressing": 0,
        "added": 0,
        "ready": 0,
        "sdmMismatch": 1,
        "verMismatch": 1,
        "featureMismatch": 1,
        "newMasterInit": 0,
        "provisioned": 0,
        "invalid": 2,
        "removed": 2,
    }
    severity = params.get(state_name, default_levels.get(state_name, 3))

    if severity == 0:
        state = "OK"
    elif severity == 1:
        state = "WARN"
    elif severity == 2:
        state = "CRIT"
    else:
        state = "UNKNOWN"

    description = switch_state_descriptions.get(state_name, "Unknown")
    msg = "Switch state: %s %s" % (description, state_name)
    if role_name != "unknown":
        msg = msg + " (role: %s)" % role_name

    metric_val = int(switch_state) if switch_state and switch_state.isdigit() else 0
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"state": metric_val, "role": 0},
            "details": "Switch role: %s" % role_name,
        },
    }