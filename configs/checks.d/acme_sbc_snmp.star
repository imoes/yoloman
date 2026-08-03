def main(ctx, params):
    base = ".1.3.6.1.4.1.9148.3.2.1.1"
    oid3 = base + ".3"
    oid4 = base + ".4"

    sys_oid_res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0",
    ], mutates=False)
    if sys_oid_res.rc != 0 or not sys_oid_res.stdout.startswith(".1.3.6.1.4.1.9148"):
        return {"changed": False, "msg": "ACME SBC not present",
                "data": {"discovery": [], "host_labels": {}}}

    if params.get("_discover"):
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": ["health_state"]},
                ]}}

    score_res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-Oqv", params.get("host", "localhost"), oid3,
    ], mutates=False)
    status_res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-Oqv", params.get("host", "localhost"), oid4,
    ], mutates=False)

    if score_res.rc != 0 or status_res.rc != 0:
        return {"changed": False, "msg": "SNMP query failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    score_str = score_res.stdout.strip()
    status_str = status_res.stdout.strip()

    if not score_str.isdigit():
        return {"changed": False, "msg": "invalid health score: %s" % score_str,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    score = int(score_str)

    map_states = {
        "0": (3, "unknown"),
        "1": (1, "initial"),
        "2": (0, "active"),
        "3": (0, "standby"),
        "4": (2, "out of service"),
        "5": (2, "unassigned"),
        "6": (1, "active (pending)"),
        "7": (1, "standby (pending)"),
        "8": (1, "out of service (pending)"),
        "9": (1, "recovery"),
    }
    health_state, health_state_readable = map_states.get(status_str, (3, "unknown"))

    lower_levels = params.get("lower_levels", ("fixed", (75, 50)))
    warn = 75
    crit = 50
    if type(lower_levels) == "list" and len(lower_levels) == 2:
        mode = lower_levels[0]
        vals = lower_levels[1]
        if mode == "fixed" and type(vals) == "list" and len(vals) == 2:
            warn = vals[0]
            crit = vals[1]

    if score <= crit:
        metric_state = "CRIT"
    elif score <= warn:
        metric_state = "WARN"
    else:
        metric_state = "OK"

    if metric_state == "CRIT":
        state = "CRIT"
    elif metric_state == "WARN":
        if health_state == 2 or health_state == 1:
            state = "WARN"
        else:
            state = "WARN"
    else:
        if health_state == 2:
            state = "CRIT"
        elif health_state == 1:
            state = "WARN"
        elif health_state == 3:
            state = "UNKNOWN"
        else:
            state = "OK"

    return {"changed": False,
            "msg": "Health state: %s, Score: %d%%" % (health_state_readable, score),
            "data": {"state": state, "metrics": {"health_state": score}, "details": ""}}