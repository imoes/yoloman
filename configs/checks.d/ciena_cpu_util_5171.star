def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        probe = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
             ".1.3.6.1.4.1.1271.2.1.5.1.2.1.4.5.1.4"],
            mutates=False,
        )
        if probe.rc != 0 or not probe.stdout.strip():
            return {"changed": False, "msg": "no ciena cpu util 5171 on this host",
                    "data": {"discovery": []}}
        warn = params.get("warn", 80.0)
        crit = params.get("crit", 90.0)
        return {"changed": False,
                "msg": "discovered 1 cpu utilization item",
                "data": {"discovery": [
                    {"item": "",
                     "params": {"warn": warn, "crit": crit},
                     "metrics": ["utilization"]},
                ]}}

    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
         ".1.3.6.1.4.1.1271.2.1.5.1.2.1.4.5.1.4"],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False,
                "msg": "no ciena 5171 cpu util data (snmp unreachable or no data)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    util = None
    cores = []
    base_oid = ".1.3.6.1.4.1.1271.2.1.5.1.2.1.4.5.1.4"
    lines = res.stdout.split("\n")
    for line in lines:
        if not line.strip():
            continue
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0]
        value = parts[1]
        suffix = oid[len(base_oid) + 1:]
        idx = suffix.split(".")[0]
        if idx == "1":
            util = int(value) if value.lstrip("-").isdigit() else 0
        else:
            index_minus_2 = str(int(idx) - 2) if idx.lstrip("-").isdigit() else idx
            cores.append((index_minus_2, int(value) if value.lstrip("-").isdigit() else 0))

    if util == None:
        return {"changed": False,
                "msg": "could not determine ciena 5171 cpu utilization",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    warn = params.get("warn", 80.0)
    crit = params.get("crit", 90.0)

    if util >= crit:
        state = "CRIT"
    elif util >= warn:
        state = "WARN"
    else:
        state = "OK"

    core_metrics = {}
    for name, val in cores:
        core_metrics["cpu_" + str(name)] = val

    metrics = {"utilization": util}
    metrics.update(core_metrics)

    core_summary = ", ".join(["cpu%s=%d" % (n, v) for n, v in cores])
    msg = "CPU utilization: %d%%" % util
    if core_summary:
        msg = msg + " (" + core_summary + ")"

    details = "Overall CPU utilization: %d%%\n" % util
    if cores:
        details = details + "Per-core utilization:\n"
        for name, val in cores:
            details = details + "  cpu%s: %d%%\n" % (name, val)

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": details}}