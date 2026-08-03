_OP_STATE_MAP = {
    1: "running normally",
    2: "not running",
    3: "currently starting",
    4: "currently stopping",
    5: "fault",
}

_SYS_LEAP_MAP = {
    0: "no Warning",
    1: "add second",
    10: "subtract second",
    11: "Alarm",
}

def _is_bluecat(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if res.rc != 0:
        return False
    sysoid = res.stdout.strip()
    return sysoid.startswith(".1.3.6.1.4.1.13315")

def _fetch_ntp_values(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.13315.3.1.4.2"
    oids = [base + ".1.1", base + ".2.1", base + ".2.2"]
    args = ["snmpget", "-v2c", "-c", community, "-Oqv", host]
    args.extend(oids)
    res = ctx.run(args, mutates=False)
    if res.rc != 0:
        return None
    lines = res.stdout.splitlines()
    if len(lines) < 3:
        return None
    return lines

def main(ctx, params):
    if not _is_bluecat(ctx, params):
        return {"changed": False, "msg": "not a BlueCat device", "data": {"discovery": []}}

    if params.get("_discover"):
        vals = _fetch_ntp_values(ctx, params)
        if vals == None:
            return {"changed": False, "msg": "no NTP data available",
                    "data": {"discovery": []}}
        if vals[0].strip() == "NULL" or vals[0].strip() == "":
            return {"changed": False, "msg": "NTP not configured",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 service",
                "data": {"discovery": [{"item": "", "params": {
                    "oper_states": {"warning": [2, 3, 4], "critical": [5]},
                    "stratum": (8, 10)
                }, "metrics": []}]}}

    vals = _fetch_ntp_values(ctx, params)
    if vals == None:
        return {"changed": False, "msg": "no NTP data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    oper_raw = vals[0].strip()
    if oper_raw == "NULL" or oper_raw == "":
        return {"changed": False, "msg": "NTP not configured",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    oper_state = int(oper_raw)
    sys_leap = int(vals[1].strip())
    stratum = int(vals[2].strip())

    oper_states = params.get("oper_states", {"warning": [2, 3, 4], "critical": [5]})
    warn_states = oper_states.get("warning", [2, 3, 4])
    crit_states = oper_states.get("critical", [5])

    state = "OK"
    if oper_state in crit_states:
        state = "CRIT"
    elif oper_state in warn_states:
        state = "WARN"
    oper_desc = _OP_STATE_MAP.get(oper_state, "unknown state %d" % oper_state)

    leap_state = "OK"
    if sys_leap == 11:
        leap_state = "CRIT"
    elif sys_leap in [1, 10]:
        leap_state = "WARN"
    leap_desc = _SYS_LEAP_MAP.get(sys_leap, "unknown leap %d" % sys_leap)

    stratum_levels = params.get("stratum", (8, 10))
    swarn = stratum_levels[0] if len(stratum_levels) >= 1 else 8
    scrit = stratum_levels[1] if len(stratum_levels) >= 2 else 10
    stratum_state = "OK"
    if stratum >= scrit:
        stratum_state = "CRIT"
    elif stratum >= swarn:
        stratum_state = "WARN"

    states = [state, leap_state, stratum_state]
    if "CRIT" in states:
        overall = "CRIT"
    elif "WARN" in states:
        overall = "WARN"
    else:
        overall = "OK"

    details = "Process: %s | Sys Leap: %s | Stratum: %d" % (oper_desc, leap_desc, stratum)
    msg = "Process: %s, Sys Leap: %s, Stratum: %d" % (oper_desc, leap_desc, stratum)

    return {"changed": False, "msg": msg,
            "data": {"state": overall, "metrics": {}, "details": details}}