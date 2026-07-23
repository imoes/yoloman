def main(ctx, params):
    # Discover mode: walk SNMP and enumerate sensors
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        # Use snmpwalk to fetch all fluid sensor entries
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On",
            host,
            ".1.3.6.1.4.1.318.1.1.10.4.7.6.1"
        ], mutates=False)

        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed: " + res.stderr,
                    "data": {"discovery": []}}

        # Parse OID lines: each entry has 4 OIDs per row (module index, sensor index, name, state)
        # SNMP output format: .1.3.6.1.4.1.318.1.1.10.4.7.6.1.1.1.1 = INTEGER: 1
        # We need to group consecutive OIDs belonging to the same sensor.
        # The MIB defines: .1 (moduleIdx), .2 (sensorIdx), .3 (sensorName), .5 (sensorState)
        # We'll parse by looking for the .1.3.6.1.4.1.318.1.1.10.4.7.6.1.1 prefix
        lines = res.stdout.splitlines()
        sensors = []

        # Process lines to group by sensor instance
        # Expected OID pattern: .1.3.6.1.4.1.318.1.1.10.4.7.6.1.1.<module_idx>.<sensor_idx>.<field>
        # where field = 1 (module index), 2 (sensor index), 3 (name), 5 (state)
        # We'll collect entries and group them.
        current = {}
        for line in lines:
            if not line.strip():
                continue
            # Parse OID and value
            parts = line.split(" = ")
            if len(parts) < 2:
                continue
            oid = parts[0].strip()
            value_part = parts[1].strip()
            # Extract type and value
            if ": " in value_part:
                vtype, value = value_part.split(": ", 1)
                value = value.strip()
            else:
                value = value_part

            # Check if this is a fluid sensor OID
            if not oid.startswith(".1.3.6.1.4.1.318.1.1.10.4.7.6.1.1."):
                continue

            # Extract indices from OID: .1.3.6.1.4.1.318.1.1.10.4.7.6.1.1.<module>.<sensor>.<field>
            suffix = oid[len(".1.3.6.1.4.1.318.1.1.10.4.7.6.1.1."):]
            idx_parts = suffix.split(".")
            if len(idx_parts) < 3:
                continue

            module_idx = idx_parts[0]
            sensor_idx = idx_parts[1]
            field = idx_parts[2]

            key = module_idx + "/" + sensor_idx

            if field == "1":  # module index (for completeness)
                current[key] = current.get(key, {})
                current[key]["module_idx"] = value
            elif field == "2":  # sensor index
                current[key] = current.get(key, {})
                current[key]["sensor_idx"] = value
            elif field == "3":  # sensor name
                current[key] = current.get(key, {})
                current[key]["sensor_name"] = value
            elif field == "5":  # sensor state: 1=fluidleak, 2=nofluid, 3=unknown
                current[key] = current.get(key, {})
                current[key]["sensor_state"] = value

        # Build discovery list
        for key, data in current.items():
            sensor_name = data.get("sensor_name", "unknown")
            # Construct item name: sensor_name module_idx/sensor_idx
            module_idx = data.get("module_idx", "")
            sensor_idx = data.get("sensor_idx", "")
            item = sensor_name + " " + module_idx + "/" + sensor_idx

            sensors.append({
                "item": item,
                "params": {},
                "metrics": []
            })

        return {
            "changed": False,
            "msg": "discovered %d fluid sensors" % len(sensors),
            "data": {"discovery": sensors}
        }

    # Check mode: examine one item
    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse item to extract module_idx/sensor_idx
    # item format: "<sensor_name> <module_idx>/<sensor_idx>"
    parts = item.rsplit(" ", 1)
    if len(parts) != 2:
        return {"changed": False, "msg": "invalid item format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sensor_name, indices = parts
    if "/" not in indices:
        return {"changed": False, "msg": "invalid indices in item",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    module_idx, sensor_idx = indices.split("/", 1)

    # Build base OID for this specific sensor
    base_oid = ".1.3.6.1.4.1.318.1.1.10.4.7.6.1.1." + module_idx + "." + sensor_idx
    # Fields: .1=moduleIdx, .2=sensorIdx, .3=sensorName, .5=sensorState

    # Fetch sensor state OID only (the most reliable way)
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run([
        "snmpget",
        "-v2c",
        "-c", community,
        "-On",
        host,
        base_oid + ".5"  # sensor state
    ], mutates=False)

    if res.rc != 0:
        return {"changed": False, "msg": "SNMP get failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse output: "OID = TYPE: value"
    lines = res.stdout.splitlines()
    if len(lines) < 1 or not lines[0].strip():
        return {"changed": False, "msg": "empty SNMP response",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    value_part = ""
    for line in lines:
        if not line.strip():
            continue
        if " = " in line:
            value_part = line.split(" = ", 1)[1].strip()
            if ": " in value_part:
                value_part = value_part.split(": ", 1)[1].strip()
            break

    # Convert to int and determine state
    if value_part.isdigit():
        state_val = int(value_part)
        if state_val == 1:
            state = "CRIT"
            msg = "Leak detected"
        elif state_val == 2:
            state = "OK"
            msg = "No leak detected"
        elif state_val == 3:
            state = "UNKNOWN"
            msg = "State Unknown"
        else:
            state = "UNKNOWN"
            msg = "Unknown state value: %d" % state_val
    else:
        state = "UNKNOWN"
        msg = "Could not parse sensor state: " + value_part

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": {}, "details": ""}
    }
