def main(ctx, params):
    if params.get("_discover"):
        sys_oid = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv",
             params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sys_oid.rc != 0 or not sys_oid.stdout.startswith(".1.3.6.1.4.1.14525.3"):
            return {"changed": False, "msg": "not a Juniper Trapeze device",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {"util": params.get("util", (80.0, 90.0))},
                     "metrics": ["utilc", "util1", "util5"]}]}}
    levels = params.get("util", (80.0, 90.0))
    warn = levels[0]
    crit = levels[1]
    base = ".1.3.6.1.4.1.14525.8.1.1.11"
    g_conf = params.get("community", "public")
    g_host = params.get("host", "localhost")
    res_c = ctx.run(["snmpget", "-v2c", "-c", g_conf, "-Oqv", g_host, base + ".1"], mutates=False)
    res_1 = ctx.run(["snmpget", "-v2c", "-c", g_conf, "-Oqv", g_host, base + ".2"], mutates=False)
    res_5 = ctx.run(["snmpget", "-v2c", "-c", g_conf, "-Oqv", g_host, base + ".3"], mutates=False)
    if res_c.rc != 0 or res_1.rc != 0 or res_5.rc != 0:
        return {"changed": False,
                "msg": "no Juniper Trapeze CPU utilization data found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    utilc = int(res_c.stdout.strip()) if res_c.stdout.strip().isdigit() else 0
    util1 = int(res_1.stdout.strip()) if res_1.stdout.strip().isdigit() else 0
    util5 = int(res_5.stdout.strip()) if res_5.stdout.strip().isdigit() else 0
    state = "OK"
    if util1 >= crit or util5 >= crit:
        state = "CRIT"
    elif util1 >= warn or util5 >= warn:
        state = "WARN"
    return {"changed": False,
            "msg": "CPU utilc %d%% util1 %d%% util5 %d%%" % (utilc, util1, util5),
            "data": {"state": state,
                     "metrics": {"utilc": utilc, "util1": util1, "util5": util5},
                     "details": ""}}