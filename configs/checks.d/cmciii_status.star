def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Probe for Rittal LCP device presence via sysDescr (.1.3.6.1.2.1.1.1.0)
    sysdesc = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"], mutates=False)
    if sysdesc.rc != 0 or not sysdesc.stdout.startswith("Rittal LCP"):
        return {"changed": False, "msg": "no Rittal LCP device found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Walk status sensors table (assuming column base OID for status)
    status_walk_oid = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2"  # Hypothetical column for status values
    walk_res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, status_walk_oid], mutates=False)
    if walk_res.rc != 0:
        return {"changed": False, "msg": "failed to walk sensors", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sensors = {}
    for line in walk_res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid, value = parts
        sensor_id = oid[len(status_walk_oid) + 1:]  # Extract index after column OID
        sensors[sensor_id] = value

    if params.get("_discover"):
        discovery = []
        for sensor_id in sorted(sensors.keys()):
            discovery.append({
                "item": sensor_id,
                "params": {"_item_key": sensor_id},
                "metrics": []
            })
        return {
            "changed": False,
            "msg": "discovered %d sensors" % len(discovery),
            "data": {"discovery": discovery}
        }

    item_key = params.get("_item_key") or params.get("item", "")
    value = sensors.get(item_key)
    if value == None:
        return {"changed": False, "msg": "no such sensor: " + str(item_key), "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = "CRIT" if value != "OK" else "OK"
    return {
        "changed": False,
        "msg": "Status: %s" % value,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }