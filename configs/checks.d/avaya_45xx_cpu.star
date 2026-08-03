def _grade_avaya_45xx_cpu(util, levels):
    warn = levels[0]
    crit = levels[1]
    if util == None:
        return "UNKNOWN"
    if util >= crit:
        return "CRIT"
    if util >= warn:
        return "WARN"
    return "OK"


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")
    levels = params.get("levels", (90.0, 95.0))
    column_oid = ".1.3.6.1.4.1.45.1.6.3.8.1.1.5.3"

    if params.get("_discover"):
        sys_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Ovqn",
             "-M", "+/usr/share/snmp/mibs:/usr/share/mibs", host,
             ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sys_res.rc != 0 or sys_res.skipped:
            return {"changed": False, "msg": "device not reachable",
                    "data": {"discovery": []}}
        sys_oid = sys_res.stdout
        sys_oid = sys_oid.strip()
        dot = sys_oid.rfind(".")
        if dot <= 0:
            return {"changed": False, "msg": "could not decode sysOID",
                    "data": {"discovery": []}}
        sys_prefix = sys_oid[:dot]
        if sys_prefix != ".1.3.6.1.4.1.45.3":
            return {"changed": False, "msg": "not an Avaya 45xx device",
                    "data": {"discovery": []}}

        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn",
                       host, column_oid], mutates=False)
        if res.rc != 0 or res.skipped:
            return {"changed": False, "msg": "no cpu data",
                    "data": {"discovery": []}}

        out = []
        count = 0
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            tail = oid[len(column_oid) + 1:]
            if not tail:
                continue
            out.append({"item": str(count),
                        "params": {"levels": levels},
                        "metrics": ["cpu_util"]})
            count = count + 1

        return {"changed": False, "msg": "discovered %d cpu items" % count,
                "data": {"discovery": out}}

    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn",
                   host, column_oid], mutates=False)
    if res.rc != 0 or res.skipped:
        return {"changed": False, "msg": "no cpu data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    found = None
    idx = 0
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        tail = oid[len(column_oid) + 1:]
        if str(idx) == item:
            found = line[sp + 1:].strip()
            break
        idx = idx + 1

    if found == None:
        return {"changed": False, "msg": "no such cpu item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    util = int(found) if found.isdigit() else 0
    state = _grade_avaya_45xx_cpu(util, levels)
    return {"changed": False,
            "msg": "CPU utilization CPU %s: %d%%" % (item, util),
            "data": {"state": state, "metrics": {"cpu_util": util}, "details": ""}}