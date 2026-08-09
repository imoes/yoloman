def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        version = params.get("version", "v2c")

        sys_oid_res = ctx.run([
            "snmpget", "-" + version, "-c", community,
            "-Ovqn", host, ".1.3.6.1.2.1.1.2.0"
        ], mutates=False)
        if sys_oid_res.rc != 0:
            return {"changed": False, "msg": "no HSM Safenet device found",
                    "data": {"discovery": []}}

        sys_oid = sys_oid_res.stdout.split()[0] if sys_oid_res.stdout.split() else ""
        if not (sys_oid.startswith(".1.3.6.1.4.1.12383") or
                sys_oid.startswith(".1.3.6.1.4.1.8072")):
            return {"changed": False, "msg": "no HSM Safenet device found",
                    "data": {"discovery": []}}

        res = ctx.run([
            "snmpget", "-v2c", "-c", community, "-Ovqn",
            host, ".1.3.6.1.4.1.12383.3.1.1.1",
            ".1.3.6.1.4.1.12383.3.1.1.2",
            ".1.3.6.1.4.1.12383.3.1.1.3",
            ".1.3.6.1.4.1.12383.3.1.1.4"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no HSM Safenet statistics available",
                    "data": {"discovery": []}}

        vals = res.stdout.strip().split("\n")
        if len(vals) < 4:
            return {"changed": False, "msg": "HSM Safenet statistics incomplete",
                    "data": {"discovery": []}}

        discovery = [
            {"item": "", "params": {},
             "metrics": ["operation_requests", "operation_errors"]},
            {"item": "", "params": {},
             "metrics": ["critical_events", "noncritical_events"]},
        ]
        return {"changed": False,
                "msg": "discovered HSM Safenet event and operation stats",
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Ovqn",
        host, ".1.3.6.1.4.1.12383.3.1.1.1",
        ".1.3.6.1.4.1.12383.3.1.1.2",
        ".1.3.6.1.4.1.12383.3.1.1.3",
        ".1.3.6.1.4.1.12383.3.1.1.4"
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "no HSM Safenet device found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    vals = res.stdout.strip().split("\n")
    if len(vals) < 4:
        return {"changed": False, "msg": "HSM Safenet statistics incomplete",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    def _to_int(s):
        v = s.strip().strip('"')
        return int(v) if v.lstrip("-").isdigit() else 0

    op_requests = _to_int(vals[0])
    op_errors = _to_int(vals[1])
    crit_events = _to_int(vals[2])
    noncrit_events = _to_int(vals[3])

    metrics = {
        "operation_requests": op_requests,
        "operation_errors": op_errors,
        "critical_events": crit_events,
        "noncritical_events": noncrit_events,
    }

    noncrit_ev = noncrit_events
    crit_lev = params.get("critical_events", None)
    noncrit_lev = params.get("noncritical_events", None)

    def _state_upper(val, levels):
        if levels == None or len(levels) < 2 or levels[0] == "no_levels":
            return "OK"
        warn_lvl = levels[0]
        crit_lvl = levels[1]
        if val >= crit_lvl:
            return "CRIT"
        if val >= warn_lvl:
            return "WARN"
        return "OK"

    state = "OK"
    worst = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    parts = ["Stats: ops=%d errs=%d crit=%d noncrit=%d" %
             (op_requests, op_errors, crit_events, noncrit_events)]

    s = _state_upper(crit_events, crit_lev)
    parts.append("critical events: %d" % crit_events)
    if worst[s] > worst[state]:
        state = s

    s = _state_upper(noncrit_ev, noncrit_lev)
    parts.append("noncritical events: %d" % noncrit_ev)
    if worst[s] > worst[state]:
        state = s

    return {"changed": False, "msg": ", ".join(parts),
            "data": {"state": state, "metrics": metrics, "details": ""}}