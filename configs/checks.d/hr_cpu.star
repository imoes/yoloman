def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.2.1.25.3.3.1.2"

    if params.get("_discover"):
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqv", host, base],
            mutates=False,
        )
        if res.rc == 127:
            return {"changed": False, "msg": "snmpwalk not found on host",
                    "data": {"discovery": []}}
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "no hrProcessorLoad data; not an SNMP host",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {"util": (80.0, 90.0)},
                     "metrics": ["util", "util_core"]},
                ]}}

    item = params.get("item", "")
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqv", host, base],
        mutates=False,
    )
    if res.rc == 127:
        return {"changed": False, "msg": "snmpwalk not found on host",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no hrProcessorLoad data found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    cores = []
    util_sum = 0.0
    num = 0
    for line in res.stdout.splitlines():
        line = line.strip()
        if line == "":
            continue
        try_val = int(line) if line.isdigit() else 0
        cores.append(("core%d" % num, try_val))
        util_sum += try_val
        num += 1

    if num == 0:
        return {"changed": False, "msg": "No data found in SNMP output",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    util = util_sum / num

    levels = params.get("util", (80.0, 90.0))
    warn = levels[0] if type(levels) == "list" or type(levels) == "tuple" else 80.0
    crit = levels[1] if type(levels) == "list" or type(levels) == "tuple" else 90.0

    if util >= crit:
        state = "CRIT"
    elif util >= warn:
        state = "WARN"
    else:
        state = "OK"

    metrics = {"util": util}
    for name, val in cores:
        metrics[name] = val

    detail = "CPU utilization: %f%% (avg over %d cores)" % (util, num)
    if cores:
        core_strs = ["%s: %d%%" % (n, v) for n, v in cores]
        detail += "\nCores: " + ", ".join(core_strs)

    return {"changed": False, "msg": detail,
            "data": {"state": state, "metrics": metrics, "details": detail}}