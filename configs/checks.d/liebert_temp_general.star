def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")

    base = ".1.3.6.1.4.1.476.1.42.3.9.20.1"

    name_oid = base + ".10"
    value_oid = base + ".20"
    unit_oid = base + ".30"

    if params.get("_discover"):
        sys_oid = ".1.3.6.1.2.1.1.2.0"
        probe = ctx.run(
            ["snmpget", "-" + version, "-c", community, "-Ovqn", host, sys_oid],
            mutates=False,
        )
        if probe.rc != 0 or probe.stdout == "":
            return {"changed": False, "msg": "no Liebert device detected",
                    "data": {"discovery": []}}
        sys_val = probe.stdout.strip()
        if not sys_val.endswith(".476.1.42"):
            prefix = ".1.3.6.1.4.1.476.1.42"
            if not (sys_val.startswith(prefix + ".") or sys_val == prefix):
                return {"changed": False, "msg": "not a Liebert device",
                        "data": {"discovery": []}}

        walk_names = ctx.run(
            ["snmpwalk", "-" + version, "-c", community, "-On", host, name_oid],
            mutates=False,
        )
        if walk_names.rc != 0 or walk_names.stdout == "":
            return {"changed": False, "msg": "no Liebert temperature sensors",
                    "data": {"discovery": []}}

        names = {}
        for line in walk_names.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            oid = line[:sp]
            val = line[sp + 1:].strip()
            if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"":
                val = val[1:-1]
            idx = oid[len(name_oid) + 1:]
            if idx == "":
                continue
            names[idx] = val

        if len(names) == 0:
            return {"changed": False, "msg": "no Liebert temperature sensors",
                    "data": {"discovery": []}}

        discovery = []
        seen = {}
        for idx in sorted(names.keys(), key=lambda x: [int(p) if p.isdigit() else p for p in x.split(".")]):
            n = names[idx]
            if n in seen:
                cnt = 2
                nn = n + " " + str(cnt)
                while nn in seen:
                    cnt = cnt + 1
                    nn = n + " " + str(cnt)
                n = nn
            seen[n] = True
            discovery.append({"item": n, "params": {}, "metrics": ["temperature"]})

        return {"changed": False, "msg": "discovered %d sensors" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    warn = params.get("warn", 40)
    crit = params.get("crit", 60)
    levels = params.get("levels")
    if levels != None and len(levels) == 2:
        warn = levels[0]
        crit = levels[1]

    sys_oid = ".1.3.6.1.2.1.1.2.0"
    probe = ctx.run(
        ["snmpget", "-" + version, "-c", community, "-Ovqn", host, sys_oid],
        mutates=False,
    )
    if probe.rc != 0 or probe.stdout == "":
        return {"changed": False, "msg": "no Liebert device detected",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sys_val = probe.stdout.strip()
    prefix = ".1.3.6.1.4.1.476.1.42"
    if not (sys_val.startswith(prefix + ".") or sys_val == prefix):
        return {"changed": False, "msg": "not a Liebert device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    walk_names = ctx.run(
        ["snmpwalk", "-" + version, "-c", community, "-On", host, name_oid],
        mutates=False,
    )
    if walk_names.rc != 0 or walk_names.stdout == "":
        return {"changed": False, "msg": "no Liebert temperature sensors",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    names = {}
    for line in walk_names.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        oid = line[:sp]
        val = line[sp + 1:].strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"":
            val = val[1:-1]
        idx = oid[len(name_oid) + 1:]
        if idx == "":
            continue
        names[idx] = val

    seen = {}
    idx_to_name = {}
    for idx in sorted(names.keys(), key=lambda x: [int(p) if p.isdigit() else p for p in x.split(".")]):
        n = names[idx]
        if n in seen:
            cnt = 2
            nn = n + " " + str(cnt)
            while nn in seen:
                cnt = cnt + 1
                nn = n + " " + str(cnt)
            n = nn
        seen[n] = True
        idx_to_name[idx] = n

    target_idx = None
    for idx in idx_to_name:
        if idx_to_name[idx] == item:
            target_idx = idx
            break

    if target_idx == None:
        return {"changed": False, "msg": "no such sensor: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    val_res = ctx.run(
        ["snmpget", "-" + version, "-c", community, "-Oqv", host,
         value_oid + "." + target_idx],
        mutates=False,
    )
    if val_res.rc != 0 or val_res.stdout == "":
        return {"changed": False, "msg": "no value for sensor: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    val_str = val_res.stdout.strip()
    if val_str == "Unavailable" or val_str == "":
        return {"changed": False, "msg": item + " unavailable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    val = 0.0
    try_parse = val_str
    try_dec = None
    if try_parse.replace(".", "", 1).isdigit() and try_parse.count(".") <= 1:
        val = float(try_parse)
        try_dec = val
    else:
        try_dec = None

    unit_res = ctx.run(
        ["snmpget", "-" + version, "-c", community, "-Oqv", host,
         unit_oid + "." + target_idx],
        mutates=False,
    )
    unit = "deg C"
    if unit_res.rc == 0 and unit_res.stdout != "":
        u = unit_res.stdout.strip()
        if len(u) >= 2 and u[0] == u[-1] and u[0] in "\"":
            u = u[1:-1]
        unit = u

    celsius = val
    u_norm = unit.replace("deg ", "").lower()
    if u_norm == "f":
        celsius = (val - 32) * (5.0 / 9.0)
    elif u_norm == "k":
        celsius = val - 273.15
    elif u_norm != "c" and u_norm != "%":
        return {"changed": False,
                "msg": "unknown unit for " + item + ": " + unit,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = "OK"
    if celsius >= crit:
        state = "CRIT"
    elif celsius >= warn:
        state = "WARN"

    return {"changed": False,
            "msg": "%s: %f deg C" % (item, celsius),
            "data": {"state": state, "metrics": {"temperature": celsius},
                     "details": "Unit: " + unit}}