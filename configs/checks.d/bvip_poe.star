def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    levels = params.get("levels", (50, 60))
    if params.get("_discover"):
        sysDescr = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"], mutates=False)
        if sysDescr.rc != 0:
            return {"changed": False, "msg": "SNMP not available", "data": {"discovery": []}}
        descr = sysDescr.stdout
        is_bvip = False
        for marker in ["flexidome", "vip-x", "dinion", "autodome"]:
            if descr.find(marker) != -1:
                is_bvip = True
                break
        if not is_bvip:
            return {"changed": False, "msg": "not a BVIP device", "data": {"discovery": []}}
        poe = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.3967.1.1.10"], mutates=False)
        if poe.rc != 0:
            return {"changed": False, "msg": "POE OID not available", "data": {"discovery": []}}
        val = poe.stdout.strip()
        if val == "" or val == "0":
            return {"changed": False, "msg": "no POE power on this device", "data": {"discovery": []}}
        if not val.isdigit():
            return {"changed": False, "msg": "POE value could not be read", "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": [{"item": "", "params": {"levels": levels}, "metrics": ["power"]}]}}
    poe = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.3967.1.1.10"], mutates=False)
    if poe.rc != 0:
        return {"changed": False, "msg": "SNMP POE data not available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    val = poe.stdout.strip()
    if val == "" or val == "0":
        return {"changed": False, "msg": "no POE power on this device", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not val.isdigit():
        return {"changed": False, "msg": "POE value invalid: %s" % val, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    watt = int(val) / 10
    state = "OK"
    if levels != None:
        warn = levels[0]
        crit = levels[1]
        if watt >= crit:
            state = "CRIT"
        elif watt >= warn:
            state = "WARN"
    msg = "%f W" % watt
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": {"power": watt}, "details": ""}}