def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        base = ".1.3.6.1.4.1.15497.1.1.1"
        col = base + ".20"
        sys_descr = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"], mutates=False)
        if sys_descr.rc == 127:
            return {"changed": False, "msg": "snmp not installed", "data": {"discovery": []}}
        if sys_descr.rc != 0:
            return {"changed": False, "msg": "snmp unavailable", "data": {"discovery": []}}
        descr = sys_descr.stdout
        if "Cisco SMA" not in descr and "sma" not in descr.lower():
            return {"changed": False, "msg": "not a Cisco SMA", "data": {"discovery": []}}
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, col], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "mail transfer threads unavailable", "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": [
            {"item": "", "params": {
                "levels_upper_total_threads": (500, 1000),
                "levels_lower_total_threads": (),
            }, "metrics": ["cisco_sma_mail_transfer_threads"]}]}}

    host = params.get("host", "localhost")
    community = params.get("community", "public")
    col = ".1.3.6.1.4.1.15497.1.1.1.20"
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, col], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "snmp not installed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no mail transfer threads data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    val = res.stdout.strip()
    if not val.isdigit():
        return {"changed": False, "msg": "invalid value: " + val, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    value = int(val)
    levels = params.get("levels_upper_total_threads", (500, 1000))
    warn = levels[0] if len(levels) > 0 and levels[0] != None else None
    crit = levels[1] if len(levels) >= 2 and levels[1] != None else None
    llevels = params.get("levels_lower_total_threads", None)
    lwarn = llevels[0] if llevels and len(llevels) > 0 and llevels[0] != None else None
    lcrit = llevels[1] if llevels and len(llevels) >= 2 and llevels[1] != None else None

    state = "OK"
    if crit != None and value >= crit:
        state = "CRIT"
    elif lwarn != None and value <= lwarn:
        state = "WARN"
    elif warn != None and value >= warn:
        state = "WARN"
    elif lcrit != None and value <= lcrit:
        state = "CRIT"

    return {"changed": False,
            "msg": "Total: %d mail transfer threads" % value,
            "data": {"state": state,
                     "metrics": {"cisco_sma_mail_transfer_threads": value},
                     "details": ""}}