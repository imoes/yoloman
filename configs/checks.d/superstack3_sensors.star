def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        probe = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Ovqn", host,
             ".1.3.6.1.2.1.1.1.0"],
            mutates=False,
        )
        if probe.rc != 0:
            return {"changed": False, "msg": "superstack3 not present",
                    "data": {"discovery": [], "host_labels": {}}}
        sysdesc = probe.stdout.strip()
        if "3com superstack 3" not in sysdesc.lower():
            return {"changed": False, "msg": "superstack3 not present",
                    "data": {"discovery": [], "host_labels": {}}}

        walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
             ".1.3.6.1.4.1.43.43.1.1.7"],
            mutates=False,
        )
        if walk.rc != 0:
            return {"changed": False, "msg": "superstack3 not present",
                    "data": {"discovery": [], "host_labels": {}}}

        names = {}
        for line in walk.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            oid = line[:sp]
            val = line[sp + 1:].strip()
            if oid.startswith(".1.3.6.1.4.1.43.43.1.1.7."):
                idx = oid[len(".1.3.6.1.4.1.43.43.1.1.7."):]
                if idx:
                    names[idx] = val

        states = {}
        w2 = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
             ".1.3.6.1.4.1.43.43.1.1.10"],
            mutates=False,
        )
        if w2.rc == 0:
            for line in w2.stdout.splitlines():
                sp = line.find(" ")
                if sp == -1:
                    continue
                oid = line[:sp]
                val = line[sp + 1:].strip()
                if oid.startswith(".1.3.6.1.4.1.43.43.1.1.10."):
                    idx = oid[len(".1.3.6.1.4.1.43.43.1.1.10."):]
                    if idx:
                        states[idx] = val

        rows = []
        for idx in sorted(names.keys()):
            rows.append({"name": names[idx], "state": states.get(idx, "")})

        out = []
        for r in rows:
            if r["state"] == "not present":
                continue
            out.append({"item": r["name"], "params": {},
                        "metrics": ["sensor_state"]})
        return {"changed": False,
                "msg": "discovered %d sensors" % len(out),
                "data": {"discovery": out, "host_labels": {}}}

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    base = ".1.3.6.1.4.1.43.43.1.1"
    nmib = "%s.7" % base
    smib = "%s.10" % base

    g = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host,
         ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    if g.rc == 127 or (g.rc != 0 and "3com superstack 3" not in g.stdout.lower()):
        return {"changed": False,
                "msg": "no superstack3 sensor found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    w = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, nmib],
        mutates=False,
    )
    names = {}
    if w.rc == 0:
        for line in w.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            oid = line[:sp]
            val = line[sp + 1:].strip()
            if oid.startswith(nmib + "."):
                idx = oid[len(nmib) + 1:]
                if idx:
                    names[idx] = val

    ws = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, smib],
        mutates=False,
    )
    states = {}
    if ws.rc == 0:
        for line in ws.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            oid = line[:sp]
            val = line[sp + 1:].strip()
            if oid.startswith(smib + "."):
                idx = oid[len(smib) + 1:]
                if idx:
                    states[idx] = val

    target = None
    for idx in names:
        if names[idx] == item:
            target = idx
            break

    if target == None:
        return {"changed": False,
                "msg": "UNKNOWN - sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = states.get(target, "")
    if state == "failure":
        verdict = "CRIT"
    elif state == "operational":
        verdict = "OK"
    elif state == "":
        verdict = "UNKNOWN"
    else:
        verdict = "WARN"

    metric = 0
    if state == "operational":
        metric = 1
    elif state == "failure":
        metric = 2

    return {"changed": False,
            "msg": "status is %s" % (state if state != "" else "unknown"),
            "data": {"state": verdict,
                     "metrics": {"sensor_state": metric},
                     "details": ""}}