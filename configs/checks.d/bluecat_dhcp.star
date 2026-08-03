_OPER_STATE_MAP = {
    1: "running normally",
    2: "not running",
    3: "currently starting",
    4: "currently stopping",
    5: "fault",
}

_DETECT_BLUECAT_OID = ".1.3.6.1.2.1.1.2.0"
_DETECT_BLUECAT_VAL = ".1.3.6.1.4.1.13315.2.1"

_BASE_OID = ".1.3.6.1.4.1.13315.3.1.1.2.1"
_COL_OPER_STATE = "1"
_COL_LEASES = "3"

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                       "-Oqv", params.get("host", "localhost"), _DETECT_BLUECAT_OID], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "bluecat not detected", "data": {"discovery": []}}
        if res.stdout.strip() != _DETECT_BLUECAT_VAL:
            return {"changed": False, "msg": "bluecat not detected", "data": {"discovery": []}}

        oper_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                            "-Oqv", params.get("host", "localhost"),
                            _BASE_OID + ".1." + _COL_OPER_STATE], mutates=False)
        leases_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                              "-Oqv", params.get("host", "localhost"),
                              _BASE_OID + ".1." + _COL_LEASES], mutates=False)

        if oper_res.rc != 0 or not oper_res.stdout.strip():
            return {"changed": False, "msg": "no dhcp operational state found",
                    "data": {"discovery": []}}

        oper_state = None
        if oper_res.stdout.strip().isdigit():
            oper_state = int(oper_res.stdout.strip())

        has_leases = leases_res.rc == 0 and leases_res.stdout.strip() and leases_res.stdout.strip().isdigit()

        if oper_state != None and oper_state != 2:
            return {"changed": False, "msg": "discovered 1 item",
                    "data": {"discovery": [{"item": "", "params": {
                        "oper_states": {"warning": [2, 3, 4], "critical": [5]}},
                        "metrics": ["leases"] if has_leases else []}]}}

        return {"changed": False, "msg": "no dhcp service found",
                "data": {"discovery": []}}

    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                   "-Oqv", params.get("host", "localhost"),
                   _BASE_OID + ".1." + _COL_OPER_STATE], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no dhcp operational state found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    oper_state = None
    if res.stdout.strip().isdigit():
        oper_state = int(res.stdout.strip())
    else:
        return {"changed": False, "msg": "cannot parse dhcp operational state",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if oper_state == 2:
        return {"changed": False, "msg": "DHCP is not running",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    warn_states = params.get("oper_states", {}).get("warning", [2, 3, 4])
    crit_states = params.get("oper_states", {}).get("critical", [5])

    state = "OK"
    if oper_state in crit_states:
        state = "CRIT"
    elif oper_state in warn_states:
        state = "WARN"

    desc = _OPER_STATE_MAP.get(oper_state, "unknown state")
    msg = "DHCP is %s" % desc

    metrics = {}
    leases_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                          "-Oqv", params.get("host", "localhost"),
                          _BASE_OID + ".1." + _COL_LEASES], mutates=False)
    if leases_res.rc == 0 and leases_res.stdout.strip().isdigit():
        leases = int(leases_res.stdout.strip())
        metrics["leases"] = leases
        msg = msg + ", %d lease%s per second" % (leases, "" if leases == 1 else "s")

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}