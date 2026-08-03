def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["winperf_ts_sessions"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "winperf_ts_sessions not available",
                    "data": {"discovery": []}}
        lines = res.stdout.splitlines()
        if len(lines) < 2:
            return {"changed": False, "msg": "no session data",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {},
                     "metrics": ["active", "inactive"]}]}}

    item = params.get("item", "")
    res = ctx.run(["winperf_ts_sessions"], mutates=False)
    lines = res.stdout.splitlines()
    if len(lines) < 2:
        return {"changed": False, "msg": "Performance counters not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    total = int(lines[1].split()[1])
    active = int(lines[2].split()[1])
    inactive = int(lines[3].split()[1])

    if active + inactive != total:
        active, inactive, total = total, active, inactive

    warn_active = params.get("active", [None, None])
    crit_active = params.get("active", [None, None])
    warn_inactive = params.get("inactive", [None, None])
    crit_inactive = params.get("inactive", [None, None])

    active_state = "OK"
    if warn_active and warn_active[0] != None and active >= warn_active[0]:
        active_state = "WARN"
    if crit_active and crit_active[1] != None and active >= crit_active[1]:
        active_state = "CRIT"

    inactive_state = "OK"
    if warn_inactive and warn_inactive[0] != None and inactive >= warn_inactive[0]:
        inactive_state = "WARN"
    if crit_inactive and crit_inactive[1] != None and inactive >= crit_inactive[1]:
        inactive_state = "CRIT"

    state = "OK"
    states = [active_state, inactive_state]
    if "CRIT" in states:
        state = "CRIT"
    elif "WARN" in states:
        state = "WARN"

    msg = "%d Active, %d Inactive" % (active, inactive)
    details = "Total sessions: %d" % total

    return {"changed": False, "msg": msg,
            "data": {"state": state,
                     "metrics": {"active": active, "inactive": inactive},
                     "details": details}}