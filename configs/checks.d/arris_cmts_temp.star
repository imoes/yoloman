def main(ctx, params):
    if params.get("_discover"):
        # Probe the real thing: ARRIS CMTS via sysObjectID
        detect = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                          "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if detect.rc != 0:
            return {"changed": False, "msg": "no arris cmts detected",
                    "data": {"discovery": [], "host_labels": {}}}
        sysobj = detect.stdout.strip()
        if sysobj != ".1.3.6.1.4.1.4998.2.1":
            return {"changed": False, "msg": "no arris cmts detected",
                    "data": {"discovery": [], "host_labels": {}}}

        # Walk the table: column 3 (name) and column 29 (temperature), -Oqn
        # base=".1.3.6.1.4.1.4998.1.1.10.1.4.2.1", oids ["3","29"]
        base = ".1.3.6.1.4.1.4998.1.1.10.1.4.2.1"
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                       "-Oqn", params.get("host", "localhost"), base + ".3"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no arris cmts detected",
                    "data": {"discovery": [], "host_labels": {}}}

        names = {}
        temps = {}
        # Build index->name from column 3
        for line in res.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            oid = line[:sp]
            val = line[sp + 1:].strip().strip('"')
            idx = oid[len(base + ".3") + 1:]
            if idx:
                names[idx] = val

        # Walk column 29 (temperature)
        res2 = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                        "-Oqn", params.get("host", "localhost"), base + ".29"], mutates=False)
        if res2.rc == 0:
            for line in res2.stdout.splitlines():
                sp = line.find(" ")
                if sp == -1:
                    continue
                oid = line[:sp]
                val = line[sp + 1:].strip().strip('"')
                idx = oid[len(base + ".29") + 1:]
                if idx:
                    temps[idx] = val

        out = []
        warn_d = params.get("warn", 40.0)
        crit_d = params.get("crit", 46.0)
        for idx in sorted(names.keys()):
            name = names[idx]
            temp = temps.get(idx, "999")
            if temp != "999":
                out.append({"item": name,
                            "params": {"levels": (warn_d, crit_d)},
                            "metrics": ["temperature"]})
        return {"changed": False,
                "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    base = ".1.3.6.1.4.1.4998.1.1.10.1.4.2.1"

    # Find the index for this item by walking column 3
    wres = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                    "-Oqn", params.get("host", "localhost"), base + ".3"], mutates=False)
    if wres.rc != 0:
        return {"changed": False, "msg": "no arris cmts detected",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    target_idx = ""
    for line in wres.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        oid = line[:sp]
        val = line[sp + 1:].strip().strip('"')
        idx = oid[len(base + ".3") + 1:]
        if idx and val == item:
            target_idx = idx
            break

    if target_idx == "":
        return {"changed": False, "msg": "Sensor not found in SNMP data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    tres = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                    "-Oqv", params.get("host", "localhost"), base + ".29." + target_idx], mutates=False)
    if tres.rc != 0:
        return {"changed": False, "msg": "Sensor not found in SNMP data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw = tres.stdout.strip().strip('"')
    temp = 0
    if raw.lstrip("-").isdigit():
        temp = int(raw)

    levels = params.get("levels", (40.0, 46.0))
    warn = levels[0] if len(levels) > 0 else 40.0
    crit = levels[1] if len(levels) > 1 else 46.0

    state = "OK"
    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"

    return {"changed": False,
            "msg": "Temperature Module %s: %s" % (item, str(temp) + " C"),
            "data": {"state": state, "metrics": {"temperature": temp}, "details": ""}}