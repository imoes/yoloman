def main(ctx, params):
    if params.get("_discover"):
        sys_descr = _snmpget(ctx, "1.3.6.1.2.1.1.1.0")
        if sys_descr == None or not sys_descr.lower().find("cisco") >= 0:
            return {"changed": False, "msg": "no cisco device", "data": {"discovery": []}}
        srst_mode = _snmpget(ctx, "1.3.6.1.4.1.9.9.441.1.2.1.0")
        if srst_mode != "1":
            return {"changed": False, "msg": "srst not in mode 1", "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": ["call_legs"]}]}}
    call_legs_str = _snmpget(ctx, "1.3.6.1.4.1.9.9.441.1.3.3")
    if call_legs_str == None or not call_legs_str.isdigit():
        return {"changed": False, "msg": "call legs not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    call_legs = int(call_legs_str)
    return {"changed": False,
            "msg": "%d call legs routed through the Cisco device since going active" % call_legs,
            "data": {"state": "OK", "metrics": {"call_legs": call_legs}, "details": ""}}


def _snmpget(ctx, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", _community(ctx), "-Oqv", _host(ctx),
                   "." + oid], mutates=False)
    if res.rc != 0 or res.skipped:
        return None
    out = res.stdout.strip()
    if len(out) == 0:
        return None
    return out


def _host(ctx):
    # check_mk passes the device via params; fall back to localhost
    h = ctx.params_host() if hasattr(ctx, "params_host") else None
    if h == None or h == "":
        return "localhost"
    return h


def _community(ctx):
    c = ctx.params_community() if hasattr(ctx, "params_community") else None
    if c == None or c == "":
        return "public"
    return c