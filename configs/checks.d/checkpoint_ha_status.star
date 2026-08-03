def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["snmpget", "-v2c",
                       "-c", params.get("community", "public"),
                       "-Oqv", params.get("host", "localhost"),
                       ".1.3.6.1.4.1.2620.1.5.2.0"], mutates=False)
        if res.rc == 127 or res.rc == 2 or not res.stdout.strip():
            return {"changed": False, "msg": "checkpoint HA not present",
                    "data": {"discovery": []}}
        installed = res.stdout.strip()
        if installed == "0":
            return {"changed": False, "msg": "checkpoint HA not installed",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": []}]}}
    return _check_ha(ctx, params)


def _get_oid(ctx, community, host, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
                  mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return None
    return res.stdout.strip()


def _check_ha(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    installed = _get_oid(ctx, community, host, ".1.3.6.1.4.1.2620.1.5.2.0")
    if installed == None:
        return {"changed": False,
                "msg": "checkpoint HA not reachable (snmpget failed)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if installed == "0":
        return {"changed": False, "msg": "Not installed",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    major = _get_oid(ctx, community, host, ".1.3.6.1.4.1.2620.1.5.3.0") or "0"
    minor = _get_oid(ctx, community, host, ".1.3.6.1.4.1.2620.1.5.4.0") or "0"
    started = _get_oid(ctx, community, host, ".1.3.6.1.4.1.2620.1.5.5.0") or ""
    state = _get_oid(ctx, community, host, ".1.3.6.1.4.1.2620.1.5.6.0") or ""
    state = state.rstrip()
    block_state = _get_oid(ctx, community, host, ".1.3.6.1.4.1.2620.1.5.7.0") or ""
    stat_code = _get_oid(ctx, community, host, ".1.3.6.1.4.1.2620.1.5.101.0") or "0"
    stat_long = _get_oid(ctx, community, host, ".1.3.6.1.4.1.2620.1.5.103.0") or ""

    summary = "Installed: v%s.%s" % (major, minor)
    worst = "OK"

    started_status = _grade(started, ["yes"], None)
    if started_status != "OK":
        summary += "; Started: %s (%s)" % (started, started_status)
        worst = _worst(worst, started_status)

    state_status = _grade(state, ["active", "standby"], None)
    if state_status != "OK":
        summary += "; Status: %s (%s)" % (state, state_status)
        worst = _worst(worst, state_status)

    block_status = _grade(block_state, ["ok"], ["initializing"])
    if block_status != "OK":
        summary += "; Blocking: %s (%s)" % (block_state, block_status)
        worst = _worst(worst, block_status)

    if stat_code != "0":
        worst = _worst(worst, "CRIT")
        summary += "; Problem: %s" % stat_long

    return {"changed": False, "msg": summary,
            "data": {"state": worst, "metrics": {}, "details": ""}}


def _grade(val, ok_vals, warn_vals):
    v = val.lower()
    if ok_vals != None and v in ok_vals:
        return "OK"
    if warn_vals != None and v in warn_vals:
        return "WARN"
    return "CRIT"


def _worst(a, b):
    order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    if order.get(b, 3) > order.get(a, 0):
        return b
    return a