def main(ctx, params):
    if params.get("_discover"):
        detect = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
            mutates=False)
        if detect.rc != 0:
            return {"changed": False,
                    "msg": "pandacom device not detected",
                    "data": {"discovery": []}}
        oid = detect.stdout.strip()
        if not oid.startswith(".1.3.6.1.4.1.3652.3"):
            return {"changed": False,
                    "msg": "not a pandacom device",
                    "data": {"discovery": []}}
        res = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"),
             ".1.3.6.1.4.1.3652.3.1.1.6"],
            mutates=False)
        if res.rc != 0:
            return {"changed": False,
                    "msg": "pandacom sys temp not available",
                    "data": {"discovery": []}}
        return {"changed": False,
                "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "System", "params": {"warn": 35.0, "crit": 40.0},
                     "metrics": ["temperature"]}]}}

    item = params.get("item", "")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"),
         ".1.3.6.1.4.1.3652.3.1.1.6"],
        mutates=False)
    if res.rc != 0:
        return {"changed": False,
                "msg": "no system temperature available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    temp = int(res.stdout.strip())
    warn = params.get("warn", 35.0)
    crit = params.get("crit", 40.0)
    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"
    else:
        state = "OK"
    return {"changed": False,
            "msg": "Temperature %d C" % temp,
            "data": {"state": state, "metrics": {"temperature": temp},
                     "details": ""}}