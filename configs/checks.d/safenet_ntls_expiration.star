def _check_levels_lower(value, levels):
    # levels: (warn, crit) or ("no_levels", None)
    if not levels or levels[0] == "no_levels":
        return "OK"
    warn = levels[0]
    crit = levels[1] if len(levels) > 1 and levels[1] != None else None
    if value == None or (crit != None and value <= crit):
        return "CRIT"
    if warn != None and value <= warn:
        return "WARN"
    return "OK"

def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")

        # Probe the real thing: check SNMP connectivity / device present.
        sys_oid_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"],
            mutates=False,
        )
        if sys_oid_res.rc != 0:
            return {"changed": False, "msg": "no SNMP response", "data": {"discovery": []}}

        # Verify it's a Safenet NTLS device via sysObjectID.
        sys_oid_val = sys_oid_res.stdout.strip()
        if (sys_oid_val.find(".1.3.6.1.4.1.12383") != 0 and
                sys_oid_val.find(".1.3.6.1.4.1.8072") != 0):
            return {"changed": False, "msg": "not a Safenet NTLS device", "data": {"discovery": []}}

        discovery = []
        discovery.append({"item": "", "params": {}, "metrics": []})
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")

    # Read the base OID table values via SNMP.
    base = ".1.3.6.1.4.1.12383.3.1.2"
    oids = ["1", "2", "3", "4", "5", "6"]
    results = {}
    all_ok = True
    for i, oid in enumerate(oids):
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, base + "." + oid],
            mutates=False,
        )
        if res.rc != 0:
            all_ok = False
            break
        results[i] = res.stdout

    if not all_ok:
        return {
            "changed": False,
            "msg": "SNMP data unavailable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    operation_status = results.get(0, "")
    connected_clients = int(results.get(1, "0"))
    links = int(results.get(2, "0"))
    successful_connections = int(results.get(3, "0"))
    failed_connections = int(results.get(4, "0"))
    expiration_date = results.get(5, "")

    # Map states: operation_status 1=OK, 2=Down(CRIT), 3=Unknown(UNKNOWN)
    state = "OK"
    summary = "Running"
    if operation_status == "2":
        state = "CRIT"
        summary = "Down"
    elif operation_status == "3":
        state = "UNKNOWN"
        summary = "Unknown"

    msg = "The NTLS server certificate expires on " + expiration_date if expiration_date else summary
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "connected_clients": connected_clients,
                "links": links,
            },
            "details": "status=%s clients=%d links=%d" % (operation_status, connected_clients, links),
        },
    }