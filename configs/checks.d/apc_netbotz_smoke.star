# Module: apc_netbotz_smoke
# Read-only Starlark check module for APC NetBotz smoke detectors via SNMP

def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Discovery mode: enumerate all smoke sensors
    if params.get("_discover"):
        base_oid = ".1.3.6.1.4.1.318.1.1.10.4.7.2.1"
        # Fetch all required fields for each sensor entry
        # OIDs: 1=ModuleIndex, 2=SensorIndex, 3=SensorName, 5=SensorState
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host,
            base_oid + ".1",  # memSmokeSensorStatusModuleIndex
            base_oid + ".2",  # memSmokeSensorStatusSensorIndex
            base_oid + ".3",  # memSmokeSensorStatusSensorName
            base_oid + ".5"   # memSmokeSensorStatusSensorState
        ], mutates=False)
        
        # Parse snmpwalk output: lines like "OID = STRING: value" or "OID = INTEGER: value"
        # We need to correlate entries by line index (snmpwalk returns each OID set on consecutive lines)
        lines = res.stdout.splitlines()
        if len(lines) < 4:
            return {
                "changed": False,
                "msg": "no sensors found",
                "data": {"discovery": []}
            }

        # Group lines into records: every 4 lines form one sensor record
        # snmpwalk returns: [module_lines], [index_lines], [name_lines], [state_lines]
        module_lines = []
        index_lines = []
        name_lines = []
        state_lines = []

        for i in range(len(lines)):
            if i % 4 == 0:
                module_lines.append(lines[i])
            elif i % 4 == 1:
                index_lines.append(lines[i])
            elif i % 4 == 2:
                name_lines.append(lines[i])
            elif i % 4 == 3:
                state_lines.append(lines[i])

        out = []
        min_len = min(len(module_lines), len(index_lines), len(name_lines), len(state_lines))
        for i in range(min_len):
            mod_line = module_lines[i]
            idx_line = index_lines[i]
            name_line = name_lines[i]
            state_line = state_lines[i]

            # Parse OID = value from each line
            # Example: ".1.3.6.1.4.1.318.1.1.10.4.7.2.1.1.3.0 = INTEGER: 3"
            # Extract the value at the end after " = "
            mod_val = mod_line.strip().rsplit(" = ", 1)[-1] if " = " in mod_line else ""
            idx_val = idx_line.strip().rsplit(" = ", 1)[-1] if " = " in idx_line else ""
            name_val = name_line.strip().rsplit(" = ", 1)[-1] if " = " in name_line else ""
            state_val = state_line.strip().rsplit(" = ", 1)[-1] if " = " in state_line else ""

            # Strip type prefixes like "INTEGER:", "STRING:", etc.
            def extract_value(v):
                if v.startswith("INTEGER: "):
                    return v[9:]
                elif v.startswith("STRING: "):
                    s = v[8:]
                    # Remove surrounding quotes if present
                    if len(s) >= 2 and s.startswith('"') and s.endswith('"'):
                        s = s[1:-1]
                    return s
                else:
                    return v.strip()

            module_idx = extract_value(mod_val)
            sensor_idx = extract_value(idx_val)
            sensor_name = extract_value(name_val)
            raw_state = extract_value(state_val)

            # Validate numeric values for module_idx, sensor_idx, raw_state
            # Guard instead of try/except
            if not module_idx.isdigit() or not sensor_idx.isdigit():
                continue  # skip malformed entries
            if not raw_state.isdigit():
                continue  # skip malformed entries

            state_code = int(raw_state)
            sensor_id = sensor_name + " " + module_idx + "/" + sensor_idx
            out.append({
                "item": sensor_id,
                "params": {},
                "metrics": []
            })

        return {
            "changed": False,
            "msg": "discovered %d sensors" % len(out),
            "data": {"discovery": out}
        }

    # Check mode: evaluate one specific sensor item
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse item string: "<sensor_name> <module>/<sensor>" -> extract module and sensor indices
    parts = item.rsplit(" ", 1)
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "invalid item format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    sensor_name, indices_part = parts
    indices = indices_part.split("/")
    if len(indices) != 2:
        return {
            "changed": False,
            "msg": "invalid item format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    module_idx, sensor_idx = indices
    # Guard instead of try/except
    if not module_idx.isdigit() or not sensor_idx.isdigit():
        return {
            "changed": False,
            "msg": "invalid item format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    base_oid = ".1.3.6.1.4.1.318.1.1.10.4.7.2.1"

    # Perform single OID fetch for the specific sensor state
    # We construct the exact OID for this sensor's state
    # OID path: base + ".5" + "." + module_idx + "." + sensor_idx
    state_oid = base_oid + ".5." + module_idx + "." + sensor_idx
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host, state_oid
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "failed to retrieve sensor state",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse output: "OID = TYPE: value"
    line = res.stdout.strip()
    if not line or not " = " in line:
        return {
            "changed": False,
            "msg": "unparseable snmpget output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    value_part = line.rsplit(" = ", 1)[-1]

    # Extract integer state value
    state_str = ""
    if value_part.startswith("INTEGER: "):
        state_str = value_part[9:]
    elif value_part.startswith("INTEGER:"):
        state_str = value_part[8:]
    else:
        state_str = value_part.strip()

    state_str = state_str.strip()

    # Guard instead of try/except
    if not state_str.isdigit():
        return {
            "changed": False,
            "msg": "invalid sensor state value: " + state_str,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    state_code = int(state_str)

    # Map state codes: 1=SMOKEDETECTED, 2=NOSMOKE, 3=UNKNOWN
    if state_code == 1:
        state = "CRIT"
        summary = "Smoke detected"
    elif state_code == 2:
        state = "OK"
        summary = "No smoke detected"
    else:
        state = "UNKNOWN"
        summary = "State Unknown"

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }
