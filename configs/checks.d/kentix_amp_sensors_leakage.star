def main(ctx, params):
    # Discovery mode: enumerate sensors by walking the SNMP tree
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        base_oid = ".1.3.6.1.4.1.37954.1"
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP walk failed",
                "data": {"discovery": []},
            }

        # Extract sensor names from OID .1.3.6.1.4.1.37954.1.2.7.1.<instance>
        sensor_items = []
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            # Sensor name OID: .1.3.6.1.4.1.37954.1.2.7.1.<instance>
            if oid_part.startswith(".1.3.6.1.4.1.37954.1.2.7.1."):
                sensor_name = parts[1].strip().strip('"')
                if sensor_name:
                    sensor_items.append({
                        "item": sensor_name,
                        "params": {},
                        "metrics": [],
                    })

        return {
            "changed": False,
            "msg": "discovered %d leakage sensors" % len(sensor_items),
            "data": {"discovery": sensor_items},
        }

    # Check mode: check one sensor's leakage state
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    # OID for leakage state: .1.3.6.1.4.1.37954.1.2.7.7.<instance>
    # We must discover the instance number for the given item name first.
    # First, get the sensor name OID to find the instance index.
    name_oid_prefix = ".1.3.6.1.4.1.37954.1.2.7.1."
    res_names = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, name_oid_prefix], mutates=False)
    if res_names.rc != 0:
        return {
            "changed": False,
            "msg": "failed to query sensor names",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Build a map from sensor name to instance index (the trailing number)
    name_to_instance = {}
    for line in res_names.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip().strip('"')
        if oid_part.startswith(name_oid_prefix):
            instance_str = oid_part[len(name_oid_prefix):]
            # instance_str should be a positive integer
            if instance_str.isdigit():
                name_to_instance[value_part] = instance_str

    # Find the instance index for this item
    if item not in name_to_instance:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    instance = name_to_instance[item]
    leakage_oid = ".1.3.6.1.4.1.37954.1.2.7.7." + instance
    res_leak = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, leakage_oid], mutates=False)
    if res_leak.rc != 0:
        return {
            "changed": False,
            "msg": "failed to query leakage state",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse the result: "OID = INTEGER: <value>"
    value = None
    for line in res_leak.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        if " = " in line:
            parts = line.split(" = ", 1)
            value_str = parts[1].strip()
            # Expect "INTEGER: <n>" or just "<n>"
            if value_str.startswith("INTEGER: "):
                value_str = value_str[len("INTEGER: "):]
            if value_str.isdigit():
                value = int(value_str)
                break

    if value == None:
        return {
            "changed": False,
            "msg": "failed to parse leakage value",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # State logic: 0 = OK, >0 = CRIT (alarm or disconnected)
    if value > 0:
        state = "CRIT"
        summary = "Alarm or disconnected"
    else:
        state = "OK"
        summary = "Connected"

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }