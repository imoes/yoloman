def _check_cpu_util(util, params, levels_default):
    warn = levels_default[0]
    crit = levels_default[1]
    lvls = params.get("levels")
    if lvls != None:
        warn = lvls[0]
        crit = lvls[1]
    state = "OK"
    if util >= crit:
        state = "CRIT"
    elif util >= warn:
        state = "WARN"
    msg = "%d%% CPU idle" % util
    return state, msg

def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")

        sys_descr = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Ovq", host, ".1.3.6.1.2.1.1.1.0"],
            mutates=False,
        )
        if sys_descr.rc != 0:
            return {"changed": False, "msg": "SNMP sysDescr unreachable", "data": {"discovery": []}}

        sys_val = sys_descr.stdout.strip()
        if sys_val == "" or sys_val == "(null)" or sys_val == "STRING: \"\"" :
            sys_val = ""
        else:
            sys_val = sys_val.replace("STRING: ", "").strip().strip('"')

        if sys_val != "":
            return {"changed": False, "msg": "not a VPLEX device", "data": {"discovery": []}}

        walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.1139.21.2.2.8.1"],
            mutates=False,
        )
        if walk.rc != 0:
            return {"changed": False, "msg": "no VPLEX CPU data", "data": {"discovery": []}}

        indices = []
        for line in walk.stdout.splitlines():
            if len(line.strip()) == 0:
                continue
            idx = line.split(" ", 1)[0].split(".", 1)[1] if "." in line.split(" ", 1)[0] else ""
            if idx != "" and idx not in indices:
                indices.append(idx)

        if len(indices) == 0:
            return {"changed": False, "msg": "no VPLEX directors found", "data": {"discovery": []}}

        discovery = []
        for idx in indices:
            name_oid = ".1.3.6.1.4.1.1139.21.2.2.1.1.3." + idx
            util_oid = ".1.3.6.1.4.1.1139.21.2.2.3.1.1." + idx

            name_res = ctx.run(
                ["snmpget", "-v2c", "-c", community, "-Oqv", host, name_oid],
                mutates=False,
            )
            util_res = ctx.run(
                ["snmpget", "-v2c", "-c", community, "-Oqv", host, util_oid],
                mutates=False,
            )

            if name_res.rc != 0 or util_res.rc != 0:
                continue

            director = name_res.stdout.strip()
            util_val = util_res.stdout.strip()
            if util_val == "" or not util_val.lstrip("-").isdigit():
                continue

            discovery.append({
                "item": director,
                "params": {"levels": (90.0, 95.0)},
                "metrics": ["cpu_util_idle"],
            })

        return {
            "changed": False,
            "msg": "discovered %d directors" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    levels_default = params.get("levels", (90.0, 95.0))

    if item == "":
        return {
            "changed": False,
            "msg": "no director specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    sys_descr = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Ovq", host, ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    if sys_descr.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP sysDescr unreachable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    sys_val = sys_descr.stdout.strip()
    if sys_val == "" or sys_val == "(null)" or sys_val == "STRING: \"\"":
        sys_val = ""
    else:
        sys_val = sys_val.replace("STRING: ", "").strip().strip('"')

    if sys_val != "":
        return {
            "changed": False,
            "msg": "not a VPLEX device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    walk = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.1139.21.2.2.8.1"],
        mutates=False,
    )
    if walk.rc != 0:
        return {
            "changed": False,
            "msg": "no VPLEX CPU data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    indices = []
    for line in walk.stdout.splitlines():
        if len(line.strip()) == 0:
            continue
        idx = line.split(" ", 1)[0].split(".", 1)[1] if "." in line.split(" ", 1)[0] else ""
        if idx != "" and idx not in indices:
            indices.append(idx)

    director_name_oid = None
    director_util_oid = None
    for idx in indices:
        name_oid = ".1.3.6.1.4.1.1139.21.2.2.1.1.3." + idx
        name_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, name_oid],
            mutates=False,
        )
        if name_res.rc != 0:
            continue
        director = name_res.stdout.strip()
        if director == item:
            util_oid = ".1.3.6.1.4.1.1139.21.2.2.3.1.1." + idx
            util_res = ctx.run(
                ["snmpget", "-v2c", "-c", community, "-Oqv", host, util_oid],
                mutates=False,
            )
            if util_res.rc != 0:
                return {
                    "changed": False,
                    "msg": "failed to read CPU utilization for " + item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
                }
            util_val = util_res.stdout.strip()
            if util_val == "" or not util_val.lstrip("-").isdigit():
                return {
                    "changed": False,
                    "msg": "invalid CPU utilization value for " + item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
                }
            util = int(util_val)
            idle = max(100 - util, 0)
            state, msg = _check_cpu_util(idle, params, levels_default)
            return {
                "changed": False,
                "msg": item + ": " + msg,
                "data": {"state": state, "metrics": {"cpu_util_idle": idle}, "details": ""},
            }

    return {
        "changed": False,
        "msg": "director not found: " + item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }