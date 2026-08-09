def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = ".1.3.6.1.4.1.318.1.1.13.3.1.2.1"
    column_oid = base_oid + ".3"

    if params.get("_discover"):
        sys_res = ctx.run([
            "snmpget", "-v2c", "-c", community, "-Oqv",
            host, ".1.3.6.1.2.1.1.2.0"
        ], mutates=False)
        if sys_res.rc != 0:
            return {"changed": False, "msg": "not an APC device", "data": {"discovery": []}}
        sys_oid = sys_res.stdout.strip()
        if not sys_oid.startswith(".1.3.6.1.4.1.318"):
            return {"changed": False, "msg": "not an APC device", "data": {"discovery": []}}

        walk_res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-Oqn",
            host, column_oid
        ], mutates=False)
        if walk_res.rc != 0:
            return {"changed": False, "msg": "no APC system events", "data": {"discovery": []}}
        if not walk_res.stdout.strip():
            return {"changed": False, "msg": "no APC system events", "data": {"discovery": []}}

        return {
            "changed": False,
            "msg": "discovered APC system events service",
            "data": {
                "discovery": [
                    {"item": "", "params": {"state": 2}, "metrics": ["event"]}
                ],
                "service_labels": {"device": "apc_inrow"},
            },
        }

    item = params.get("item", "")
    state_num = params.get("state", 2)
    state_map = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
    threshold_state = state_map.get(state_num, "CRIT")

    walk_res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-Oqn",
        host, column_oid
    ], mutates=False)
    if walk_res.rc != 0 or not walk_res.stdout.strip():
        return {
            "changed": False,
            "msg": "no system events found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    events = []
    for line in walk_res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        value = line[sp + 1:]
        idx = oid[len(column_oid) + 1:]
        if idx:
            events.append(value)

    if not events:
        return {
            "changed": False,
            "msg": "No service events",
            "data": {"state": "OK", "metrics": {}, "details": ""},
        }

    metric_val = len(events)
    return {
        "changed": False,
        "msg": "System events: %d" % metric_val,
        "data": {
            "state": threshold_state,
            "metrics": {"event": metric_val},
            "details": "\n".join(events),
        },
    }