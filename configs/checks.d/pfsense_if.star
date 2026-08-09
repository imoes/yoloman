def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(
            [
                "snmpwalk",
                "-v2c",
                "-c",
                params.get("community", "public"),
                "-Oqn",
                params.get("host", "localhost"),
                ".1.3.6.1.4.1.12325.1.200.1.8.2.1.2",
            ],
            mutates=False,
        )
        if res.rc != 0:
            return {"changed": False, "msg": "pfsense_if not discovered", "data": {"discovery": []}}
        names = {}
        for line in res.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            idx = oid[len(".1.3.6.1.4.1.12325.1.200.1.8.2.1.2") + 1:]
            if not idx:
                continue
            names[idx] = "pfsense_if"
        out = []
        for idx, nm in names.items():
            out.append({"item": nm, "params": {"ipv4_in_blocked": params.get("ipv4_in_blocked", [100.0, 10000.0])}, "metrics": ["ip4_in_blocked"]})
        return {"changed": False, "msg": "discovered %d interfaces" % len(out), "data": {"discovery": out}}

    item = params.get("item", "")
    base = ".1.3.6.1.4.1.12325.1.200.1.8.2.1"
    res_name = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), base + ".2.1"], mutates=False)
    if res_name.rc != 0 or not res_name.stdout:
        return {"changed": False, "msg": "no pfsense interface data: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res_name.stdout.strip() != item:
        return {"changed": False, "msg": "interface not found: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), base + ".12.1"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no pfsense interface data: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    raw = res.stdout.strip()
    raw = raw.strip('"')
    val = 0
    if raw.lstrip("-").isdigit():
        val = int(raw)
    lvls = params.get("ipv4_in_blocked", [100.0, 10000.0])
    warn = lvls[0] if len(lvls) >= 1 else 100.0
    crit = lvls[1] if len(lvls) >= 2 else 10000.0
    if val >= crit:
        state = "CRIT"
    elif val >= warn:
        state = "WARN"
    else:
        state = "OK"
    return {"changed": False, "msg": "%s: %s blocked packets" % (item, raw), "data": {"state": state, "metrics": {"ip4_in_blocked": val}, "details": "Incoming IPv4 packets blocked"}}