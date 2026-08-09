def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    if params.get("_discover"):
        sys_descr = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"],
            mutates=False,
        )
        if sys_descr.rc != 0 or "isilon" not in sys_descr.stdout:
            return {"changed": False, "msg": "no EMC Isilon device found",
                    "data": {"discovery": [], "host_labels": {}}}
        base = ".1.3.6.1.4.1.12124.2.2.3"
        oids = ["1", "2", "3", "4"]
        values = []
        for oid_suffix in oids:
            res = ctx.run(
                ["snmpget", "-v2c", "-c", community, "-Oqv", host, base + "." + oid_suffix],
                mutates=False,
            )
            if res.rc != 0:
                return {"changed": False, "msg": "no CPU utilization data",
                        "data": {"discovery": []}}
            values.append(res.stdout)
        if len(values) < 4:
            return {"changed": False, "msg": "incomplete CPU utilization data",
                    "data": {"discovery": []}}
        levels = params.get("util", (80, 90))
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {"util": levels},
                     "metrics": ["user", "system", "interrupt"]},
                ], "host_labels": {"cmk/isilon": "true"}}}

    item = params.get("item", "")
    base = ".1.3.6.1.4.1.12124.2.2.3"
    oids = ["1", "2", "3", "4"]
    values = []
    for oid_suffix in oids:
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, base + "." + oid_suffix],
            mutates=False,
        )
        if res.rc != 0:
            return {"changed": False, "msg": "no CPU utilization data",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        values.append(res.stdout)
    if len(values) < 4:
        return {"changed": False, "msg": "incomplete CPU utilization data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    user_perc = (int(values[0]) + int(values[1])) * 0.1
    system_perc = int(values[2]) * 0.1
    interrupt_perc = int(values[3]) * 0.1
    total_perc = user_perc + system_perc + interrupt_perc

    levels = params.get("util", (80, 90))
    warn = levels[0]
    crit = levels[1]
    if total_perc >= crit:
        state = "CRIT"
    elif total_perc >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {"changed": False,
            "msg": "Node CPU utilization: %f%%" % total_perc,
            "data": {
                "state": state,
                "metrics": {"user": user_perc, "system": system_perc,
                            "interrupt": interrupt_perc},
                "details": "Total: %f%%, User: %f%%, System: %f%%, Interrupt: %f%%" % (total_perc, user_perc, system_perc, interrupt_perc),
            }}