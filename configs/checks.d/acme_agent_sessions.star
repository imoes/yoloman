def main(ctx, params):
    if params.get("_discover"):
        sysOid = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sysOid.rc != 0 or not sysOid.stdout.strip().startswith(".1.3.6.1.4.1.9148"):
            return {"changed": False, "msg": "no ACME device detected",
                    "data": {"discovery": []}}
        walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
             "-Oqn", params.get("host", "localhost"),
             ".1.3.6.1.4.1.9148.3.2.1.2.2.1.2"],
            mutates=False,
        )
        if walk.rc != 0:
            return {"changed": False, "msg": "no ACME sessions found",
                    "data": {"discovery": []}}
        out = []
        for line in walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0]
            hostname = parts[1].strip().strip('"')
            out.append({"item": hostname, "params": {},
                        "metrics": [], "service_labels": {"acme_agent": hostname}})
        return {"changed": False, "msg": "discovered %d agent sessions" % len(out),
                "data": {"discovery": out,
                         "host_labels": {"cmk/acme_device": "true"}}}
    item = params.get("item", "")
    base = ".1.3.6.1.4.1.9148.3.2.1.2.2.1"
    state_oid = base + ".22"
    state_res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"),
         state_oid + "." + item],
        mutates=False,
    )
    if state_res.rc != 0 or not state_res.stdout.strip():
        return {"changed": False, "msg": "no data for session " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    st = state_res.stdout.strip()
    map_states = {
        "0": (0, "disabled"),
        "1": (2, "out of service"),
        "2": (0, "standby"),
        "3": (0, "in service"),
        "4": (1, "contraints violation"),
        "5": (1, "in service timed out"),
        "6": (1, "oos provisioned response"),
    }
    if st not in map_states:
        return {"changed": False, "msg": "unknown state %s for " % st + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    dev_state, dev_state_readable = map_states[st]
    names = {4: "OK", 3: "CRIT", 2: "CRIT", 1: "WARN", 0: "OK"}
    state = names.get(dev_state, "UNKNOWN")
    return {"changed": False,
            "msg": "Status: %s" % dev_state_readable,
            "data": {"state": state, "metrics": {}, "details": ""}}