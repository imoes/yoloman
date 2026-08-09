def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")

        sys_descr = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv",
                             host, ".1.3.6.1.2.1.1.1.0"], mutates=False)
        if sys_descr.rc == 127 or sys_descr.rc != 0:
            return {"changed": False, "msg": "not a cisco device",
                    "data": {"discovery": []}}
        desc = sys_descr.stdout.strip().lower()
        if "cisco" not in desc or "nx-os" in desc:
            return {"changed": False, "msg": "not a cisco device",
                    "data": {"discovery": []}}

        exists_probe = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv",
                                host, ".1.3.6.1.4.1.9.9.109.1.1.1.1.2.1"],
                               mutates=False)
        if exists_probe.rc != 0:
            return {"changed": False, "msg": "no cisco cpu data",
                    "data": {"discovery": []}}

        cpu_base = ".1.3.6.1.4.1.9.9.109.1.1.1.1"
        cpu_walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn",
                            host, cpu_base + ".1"], mutates=False)
        if cpu_walk.rc != 0:
            return {"changed": False, "msg": "no cisco cpu data",
                    "data": {"discovery": []}}

        ent_base = ".1.3.6.1.2.1.47.1.1.1.1"
        ent_walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn",
                            host, ent_base + ".1"], mutates=False)
        ent_name = {}
        ent_class = {}
        for line in ent_walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0]
            value = parts[1].strip()
            if oid.endswith(".7"):
                ent_name[oid[:-2]] = value
            elif oid.endswith(".5"):
                ent_class[oid[:-2]] = value

        parsed = {}
        for line in cpu_walk.stdout.splitlines():
            fields = line.split()
            if len(fields) < 3:
                continue
            full_oid = fields[0]
            cpu_id = fields[0]
            phys_idx = fields[1]
            util = fields[2]

            suffix = full_oid[len(cpu_base) + 1:]
            dot = suffix.find(".")
            index = suffix if dot == -1 else suffix[:dot]

            name = ent_name.get(ent_base + "." + index + ".7", "")
            phys_class = ent_class.get(ent_base + "." + index + ".5", "")

            lower_class = phys_class.lower()
            if lower_class in ("fan", "sensor", "12", "13"):
                continue

            if name and name.lower().startswith("cpu"):
                name = name[4:]
            item_name = name if name else cpu_id

            if phys_class and phys_class.lower() not in ("cpu", "unknown", ""):
                continue

            parsed[item_name] = float(util)

        if not parsed:
            return {"changed": False, "msg": "no cisco cpu instances",
                    "data": {"discovery": []}}

        discovery = []
        for it in parsed:
            discovery.append({"item": it, "params": {"levels": (80.0, 90.0)},
                              "metrics": ["util"]})
        discovery.append({"item": "average", "params": {"levels": (80.0, 90.0)},
                          "metrics": ["util"]})

        return {"changed": False,
                "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    cpu_base = ".1.3.6.1.4.1.9.9.109.1.1.1.1"
    cpu_walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn",
                        host, cpu_base + ".1"], mutates=False)
    if cpu_walk.rc == 127:
        return {"changed": False, "msg": "snmp not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if cpu_walk.rc != 0:
        return {"changed": False, "msg": "no cisco cpu data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    ent_base = ".1.3.6.1.2.1.47.1.1.1.1"
    ent_walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn",
                        host, ent_base + ".1"], mutates=False)
    ent_name = {}
    ent_class = {}
    for line in ent_walk.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0]
        value = parts[1].strip()
        if oid.endswith(".7"):
            ent_name[oid[:-2]] = value
        elif oid.endswith(".5"):
            ent_class[oid[:-2]] = value

    parsed = {}
    for line in cpu_walk.stdout.splitlines():
        fields = line.split()
        if len(fields) < 3:
            continue
        full_oid = fields[0]
        cpu_id = fields[0]
        phys_idx = fields[1]
        util = fields[2]

        suffix = full_oid[len(cpu_base) + 1:]
        dot = suffix.find(".")
        index = suffix if dot == -1 else suffix[:dot]

        name = ent_name.get(ent_base + "." + index + ".7", "")
        phys_class = ent_class.get(ent_base + "." + index + ".5", "")

        lower_class = phys_class.lower()
        if lower_class in ("fan", "sensor", "12", "13"):
            continue

        if name and name.lower().startswith("cpu"):
            name = name[4:]
        item_name = name if name else cpu_id

        if phys_class and phys_class.lower() not in ("cpu", "unknown", ""):
            continue

        parsed[item_name] = float(util)

    if item == "average":
        if not parsed:
            return {"changed": False, "msg": "no cisco cpu data for average",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        total = 0.0
        count = 0
        for k in parsed:
            total += parsed[k]
            count += 1
        util = total / count
    elif item in parsed:
        util = parsed[item]
    else:
        return {"changed": False, "msg": item + ": no such cpu instance",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    levels = params.get("levels", (80.0, 90.0))
    warn = levels[0] if len(levels) > 0 else 80.0
    crit = levels[1] if len(levels) > 1 else 90.0

    if util >= crit:
        state = "CRIT"
    elif util >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {"changed": False,
            "msg": item + " " + str(util) + "%",
            "data": {"state": state, "metrics": {"util": util}, "details": ""}}