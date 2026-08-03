def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = "1.3.6.1.4.1.3711.15.1.1.2"
    name_col = base_oid + ".1"
    state_col = base_oid + ".5"

    sys_descr = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv", host, "1.3.6.1.2.1.1.1.0"
    ], mutates=False)
    sys_oid_val = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv", host, "1.3.6.1.2.1.1.2.0"
    ], mutates=False)

    if sys_descr.rc == 127 or sys_oid_val.rc == 127:
        return {"changed": False, "msg": "snmp not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    descr = sys_descr.stdout.strip()
    sys_oid = sys_oid_val.stdout.strip()
    if descr == "" or sys_oid == "" or not sys_oid.startswith("1.3.6.1.4.1.3711.15.1"):
        return {"changed": False, "msg": "not a Knürr device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, name_col],
                       mutates=False)
        discovery = []
        seen = {}
        for line in walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            val = parts[1]
            idx = oid[len(name_col):]
            if not idx:
                continue
            if idx not in seen:
                seen[idx] = val
                discovery.append({"item": val, "params": {}, "metrics": ["triggered"]})
        return {"changed": False,
                "msg": "discovered %d sensors" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    walk = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, name_col],
                   mutates=False)
    index_for_item = None
    for line in walk.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        val = parts[1]
        idx = oid[len(name_col):]
        if val == item:
            index_for_item = idx
            break

    if index_for_item == None:
        return {"changed": False, "msg": "Sensor no longer found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state_res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv", host, state_col + "." + index_for_item
    ], mutates=False)
    state_val = state_res.stdout.strip()
    triggered = 1 if state_val != "0" else 0

    verdict = "CRIT" if state_val != "0" else "OK"
    summary = "Sensor triggered" if triggered else "Sensor not triggered"
    return {"changed": False, "msg": summary,
            "data": {"state": verdict, "metrics": {"triggered": triggered}, "details": ""}}