def _walk_column(ctx, oid, community, host):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid], mutates=False)
    rows = []
    if res.rc != 0 or not res.stdout:
        return rows
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        rows.append((line[:sp], line[sp + 1:]))
    return rows

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    sys_descr = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"], mutates=False)
    if sys_descr.rc == 127:
        return {"changed": False, "msg": "snmp not installed; cannot check cisco_fantray",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if sys_descr.rc != 0 or not sys_descr.stdout or sys_descr.stdout.find("cisco") < 0:
        return {"changed": False, "msg": "not a cisco device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status_base = ".1.3.6.1.4.1.9.9.117.1.4.1.1.1"
    name_base = ".1.3.6.1.2.1.47.1.1.1.1.7"

    statuses = {}
    for oid, val in _walk_column(ctx, status_base, community, host):
        end_oid = oid[len(status_base) + 1:]
        statuses[end_oid] = val

    names = {}
    for oid, val in _walk_column(ctx, name_base, community, host):
        end_oid = oid[len(name_base) + 1:]
        names[end_oid] = val

    if not statuses:
        if params.get("_discover"):
            return {"changed": False, "msg": "no fan tray data",
                    "data": {"discovery": [], "host_labels": {"cmk/snmp": "true", "cmk/vendor": "cisco"}}}
        return {"changed": False, "msg": "no fan tray data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    map_states = {
        "1": ("UNKNOWN", "unknown"),
        "2": ("OK", "powered on"),
        "3": ("CRIT", "powered down"),
        "4": ("CRIT", "partial failure, needs replacement as soon as possible."),
    }

    parsed = {}
    entries_by_name = {}
    for end_oid, raw_name in names.items():
        if end_oid not in statuses:
            continue
        nm = (raw_name or "").strip() or end_oid
        entries_by_name.setdefault(nm, [])
        sv = statuses[end_oid]
        entries_by_name[nm].append(map_states.get(sv, ("UNKNOWN", "unexpected(%s)" % sv)))

    for n, infos in entries_by_name.items():
        if len(infos) > 1:
            for k, info in enumerate(infos):
                parsed["%s-%d" % (n, k + 1)] = info
        else:
            parsed[n] = infos[0]

    if params.get("_discover"):
        out = []
        for item in parsed:
            out.append({"item": item, "params": {"state": "OK"},
                        "metrics": ["fan_status"]})
        return {"changed": False, "msg": "discovered %d fan tray items" % len(out),
                "data": {"discovery": out, "host_labels": {"cmk/snmp": "true", "cmk/vendor": "cisco"}}}

    item = params.get("item", "")
    if item in parsed:
        st, rd = parsed[item]
        return {"changed": False, "msg": "Fan %s: %s" % (item, rd),
                "data": {"state": st, "metrics": {"fan_status": 0 if st == "OK" else 1}, "details": ""}}
    return {"changed": False, "msg": "fan tray item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}