def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        sys_descr = _snmp_get(ctx, host, community, "1.3.6.1.2.1.1.1.0")
        if "BX600" not in sys_descr:
            return {"changed": False, "msg": "not a BX600 device",
                    "data": {"discovery": []}}
        load1 = _snmp_get(ctx, host, community, "1.3.6.1.4.1.2021.10.1.6")
        if load1 == "":
            return {"changed": False, "msg": "no load data",
                    "data": {"discovery": []}}
        return {"changed": False,
                "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {"levels1": None, "levels5": None, "levels15": (5.0, 20.0)},
                     "metrics": ["load_avg_1", "load_avg_5", "load_avg_15", "load_avg_1_pct", "load_avg_5_pct", "load_avg_15_pct"]},
                ]}}
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    sys_descr = _snmp_get(ctx, host, community, "1.3.6.1.2.1.1.1.0")
    if "BX600" not in sys_descr:
        return {"changed": False, "msg": "not a BX600 device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    vals = _snmp_walk_load(ctx, host, community, "1.3.6.1.4.1.2021.10.1.6")
    if len(vals) < 3:
        return {"changed": False, "msg": "no load data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    load1 = vals[0]
    load5 = vals[1]
    load15 = vals[2]
    num_cpus = 1
    l1_pct = load1 / num_cpus * 100
    l5_pct = load5 / num_cpus * 100
    l15_pct = load15 / num_cpus * 100
    lvls1 = params.get("levels1")
    lvls5 = params.get("levels5")
    lvls15 = params.get("levels15", (5.0, 20.0))
    state, worst = _grade(load1, lvls1)
    s2, w2 = _grade(load5, lvls5)
    if w2 > worst:
        state, worst = s2, w2
    s3, w3 = _grade(load15, lvls15)
    if w3 > worst:
        state, worst = s3, w3
    msg = "load avg: 1min %f, 5min %f, 15min %f pct %d%%/%d%%/%d%%" % (load1, load5, load15, int(l1_pct), int(l5_pct), int(l15_pct))
    return {"changed": False, "msg": msg,
            "data": {
                "state": state,
                "metrics": {
                    "load_avg_1": load1,
                    "load_avg_5": load5,
                    "load_avg_15": load15,
                    "load_avg_1_pct": l1_pct,
                    "load_avg_5_pct": l5_pct,
                    "load_avg_15_pct": l15_pct,
                },
                "details": "",
            }}


def _grade(value, levels):
    if levels == None:
        return ("OK", 0)
    warn = levels[0]
    crit = levels[1]
    if value >= crit:
        return ("CRIT", 2)
    if value >= warn:
        return ("WARN", 1)
    return ("OK", 0)


def _snmp_get(ctx, host, community, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return ""
    return res.stdout.strip()


def _snmp_walk_load(ctx, host, community, oid):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return []
    out = []
    for line in res.stdout.splitlines():
        v = line.strip()
        if v != "" and _is_num(v):
            out.append(float(v))
    return out


def _is_num(s):
    if len(s) == 0:
        return False
    i = 0
    if s[0] == "-":
        i = 1
        if len(s) == 1:
            return False
    seen_dot = False
    while i < len(s):
        c = s[i]
        if c == ".":
            if seen_dot:
                return False
            seen_dot = True
        elif c < "0" or c > "9":
            return False
        i += 1
    return True