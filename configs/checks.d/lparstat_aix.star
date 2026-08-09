def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["lparstat", "-E", "1", "1"], mutates=False)
        if not res.stdout or res.rc != 0:
            return {"changed": False, "msg": "no lparstat available",
                    "data": {"discovery": []}}

        lines = res.stdout.splitlines()
        if len(lines) < 4:
            return {"changed": False, "msg": "update required",
                    "data": {"discovery": []}}

        config_words = lines[0].split()
        system_config = {}
        for w in config_words:
            if "=" in w:
                parts = w.split("=", 1)
                if len(parts) == 2:
                    system_config[parts[0]] = parts[1]

        if system_config.get("smt", "").lower() == "on":
            system_config["smt"] = "2"

        keys = lines[1].split()
        values = lines[3].split()

        util = {}
        cpu = {}
        for index, key in enumerate(keys):
            if index >= len(values):
                continue
            name = key.lstrip("%")
            uom = "%" if "%" in key else ""
            vstr = values[index]
            if vstr.lstrip("-").replace(".", "", 1).isdigit():
                value = float(vstr)
            else:
                continue

            if name in ("user", "sys", "idle", "wait"):
                cpu[name] = value
            else:
                util[name] = (value, uom)

        section = {"system_config": system_config, "util": util, "cpu": cpu}

        discovery = []

        if len(util) > 0:
            discovery.append({"item": "", "params": {}, "metrics": list(util.keys())})

        cpu_keys = set(cpu.keys())
        if "user" in cpu_keys and "sys" in cpu_keys and "wait" in cpu_keys and "idle" in cpu_keys:
            discovery.append({"item": "", "params": {}, "metrics": ["cpu_util"]})

        return {"changed": False,
                "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")

    res = ctx.run(["lparstat", "-E", "1", "1"], mutates=False)
    if not res.stdout or res.rc != 0:
        return {"changed": False, "msg": "no lparstat available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = res.stdout.splitlines()
    if len(lines) < 4:
        return {"changed": False, "msg": "Please upgrade your AIX agent.",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    config_words = lines[0].split()
    system_config = {}
    for w in config_words:
        if "=" in w:
            parts = w.split("=", 1)
            if len(parts) == 2:
                system_config[parts[0]] = parts[1]

    if system_config.get("smt", "").lower() == "on":
        system_config["smt"] = "2"

    keys = lines[1].split()
    values = lines[3].split()

    util = {}
    cpu = {}
    for index, key in enumerate(keys):
        if index >= len(values):
            continue
        name = key.lstrip("%")
        uom = "%" if "%" in key else ""
        vstr = values[index]
        if vstr.lstrip("-").replace(".", "", 1).isdigit():
            value = float(vstr)
        else:
            continue

        if name in ("user", "sys", "idle", "wait"):
            cpu[name] = value
        else:
            util[name] = (value, uom)

    section = {"system_config": system_config, "util": util, "cpu": cpu}
    cpu_keys = set(cpu.keys())

    if len(util) > 0:
        metrics = {}
        msg_parts = []
        for name in util:
            val = util[name][0]
            uom = util[name][1]
            metrics["lparstat_" + name] = val
            msg_parts.append("%s: %s%s" % (name.title(), str(val), uom))
        return {"changed": False, "msg": ", ".join(msg_parts),
                "data": {"state": "OK", "metrics": metrics, "details": ""}}

    if "user" in cpu_keys and "sys" in cpu_keys and "wait" in cpu_keys and "idle" in cpu_keys:
        warn = params.get("warn", 80)
        crit = params.get("crit", 90)
        cpu_util = 100.0 - cpu.get("idle", 0.0)
        state = "OK"
        if cpu_util >= crit:
            state = "CRIT"
        elif cpu_util >= warn:
            state = "WARN"
        return {"changed": False,
                "msg": "CPU utilization: %s%%" % str(cpu_util),
                "data": {"state": state, "metrics": {"cpu_util": cpu_util},
                         "details": ""}}

    cpu_entitlement = 0.0
    ent_val = system_config.get("ent")
    if ent_val != None:
        ent_str = str(ent_val)
        if ent_str.lstrip("-").replace(".", "", 1).isdigit():
            cpu_entitlement = float(ent_str)
        else:
            cpu_entitlement = 0.0

    physc_pair = util.get("physc")
    if physc_pair != None:
        physc_value = physc_pair[0]
    else:
        physc_value = 0.0

    metrics = {"cpu_entitlement": cpu_entitlement, "cpu_entitlement_util": physc_value}
    return {"changed": False,
            "msg": "Physical CPU consumption: %s CPUs, Entitlement: %s CPUs" % (str(physc_value), str(cpu_entitlement)),
            "data": {"state": "OK", "metrics": metrics, "details": ""}}