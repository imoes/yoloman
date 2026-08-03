def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = ".1.3.6.1.4.1.2636.3.1.10.1.8"
    sys_oid = ".1.3.6.1.2.1.1.2.0"
    juniper_prefix = ".1.3.6.1.4.1.2636.1.1.1"

    state_map = {
        "1": "unknown or unavailable",
        "2": "OK, good, normally working",
        "3": "alarm, warning, marginally working (minor)",
        "4": "alert, failed, not working (major)",
        "5": "OK, online as an active primary",
        "6": "alarm, offline, not running (minor)",
        "7": "off-line, not running",
        "8": "entering state of ok, good, normally working",
        "9": "entering state of alarm, warning, marginally working",
        "10": "entering state of alert, failed, not working",
        "11": "entering state of ok, on-line as an active primary",
        "12": "entering state of off-line, not running",
    }

    default_params = {
        "state_1": 3,
        "state_2": 0,
        "state_3": 1,
        "state_4": 2,
        "state_5": 0,
        "state_6": 1,
        "state_7": 2,
        "state_8": 0,
        "state_9": 1,
        "state_10": 2,
        "state_11": 0,
        "state_12": 1,
    }

    def state_name(code):
        return "state_" + code

    def state_label(code):
        return state_map.get(code, "unhandled alarm type '%s'" % code)

    def state_level(code):
        return default_params.get(state_name(code), 3)

    if params.get("_discover"):
        sys_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, sys_oid], mutates=False)
        if sys_res.rc != 0:
            return {"changed": False, "msg": "not a juniper device", "data": {"discovery": []}}
        sys_val = sys_res.stdout.strip()
        if not sys_val.startswith(juniper_prefix):
            return {"changed": False, "msg": "not a juniper device", "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": [{"item": "", "params": default_params, "metrics": []}]}}

    alarm_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base_oid], mutates=False)
    if alarm_res.rc != 0 or not alarm_res.stdout.strip():
        return {"changed": False, "msg": "no juniper alarm data available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    code = alarm_res.stdout.strip()
    level = state_level(code)
    summary = state_label(code)
    if level == 0:
        state = "OK"
    elif level == 1:
        state = "WARN"
    elif level == 2:
        state = "CRIT"
    else:
        state = "UNKNOWN"
    return {"changed": False, "msg": "Status: %s" % summary, "data": {"state": state, "metrics": {}, "details": ""}}