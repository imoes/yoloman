def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Base OID for OpenBSD sensors (from Checkmk source)
    base_oid = ".1.3.6.1.4.1.30155.2.1.2.1"
    # OIDs: descr(2), sensortype(3), value(5), unit(6), state(7)
    oids = ["%s.2" % base_oid, "%s.3" % base_oid, "%s.5" % base_oid, "%s.6" % base_oid, "%s.7" % base_oid]

    # Discovery mode
    if params.get("_discover"):
        # Probe sensors
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host] + oids, mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP query failed",
                "data": {"discovery": []}
            }

        # Parse snmpwalk output: each line looks like "OID.index = TYPE: value"
        lines = res.stdout.splitlines()
        # Group by index (each sensor index has 5 consecutive lines for the 5 OIDs)
        # We expect 5 lines per sensor index
        sensors = {}
        i = 0
        while i < len(lines):
            # Try to collect 5 lines with the same index
            if i + 4 >= len(lines):
                break

            # Check if all five lines share the same base OID index
            indices = []
            values = []
            for j in range(5):
                line = lines[i + j].strip()
                # Format: OID.index = TYPE: value
                eq_idx = line.find("=")
                if eq_idx == -1:
                    break
                oid_part = line[:eq_idx].strip()
                val_part = line[eq_idx + 1:].strip()
                # Extract index: find last dot and take what's after
                dot_idx = oid_part.rfind(".")
                if dot_idx == -1:
                    break
                idx_str = oid_part[dot_idx + 1:]
                indices.append(idx_str)
                values.append(val_part)

            if len(indices) != 5 or len(set(indices)) != 1:
                # Not a full set of 5 values for the same sensor; skip
                i += 1
                continue

            descr_raw = values[0]
            sensortype_raw = values[1]
            value_raw = values[2]
            unit_raw = values[3]
            state_raw = values[4]

            # Clean type: strip "Integer:" or similar prefixes
            sensortype = sensortype_raw
            if sensortype.startswith("INTEGER: "):
                sensortype = sensortype[9:]
            elif sensortype.startswith("Gauge32: "):
                sensortype = sensortype[9:]
            elif sensortype.startswith("INTEGER:"):
                sensortype = sensortype[8:]
            elif sensortype.startswith("Gauge32:"):
                sensortype = sensortype[8:]

            # Clean value: strip type prefixes
            value_clean = value_raw
            for prefix in ["INTEGER: ", "Gauge32: ", "STRING: ", "Counter32: ", "Counter64: "]:
                if value_clean.startswith(prefix):
                    value_clean = value_clean[len(prefix):]
                    break
            # Strip quotes if STRING
            if value_clean.startswith('"') and value_clean.endswith('"'):
                value_clean = value_clean[1:-1]

            # Clean descr: strip type prefixes, remove quotes
            descr = descr_raw
            for prefix in ["STRING: "]:
                if descr.startswith(prefix):
                    descr = descr[len(prefix):]
                    break
            if descr.startswith('"') and descr.endswith('"'):
                descr = descr[1:-1]

            # Skip non-temperature sensors (type 0 only for temp)
            if sensortype != "0":
                i += 5
                continue

            # Skip invalid temperature (sentinel -273.15)
            if value_clean == "-273.15":
                i += 5
                continue

            # Map state: 0=UNKNOWN, 1=OK, 2=WARN, 3=CRIT
            state_map = {"0": "UNKNOWN", "1": "OK", "2": "WARN", "3": "CRIT"}
            state_str = state_raw
            if state_str.startswith("INTEGER: "):
                state_str = state_str[9:]
            elif state_str.startswith("Gauge32: "):
                state_str = state_str[9:]
            if state_str in state_map:
                state_val = state_map[state_str]
            else:
                state_val = "UNKNOWN"

            sensors[descr] = {
                "state": state_val,
                "value": value_clean,
                "unit": unit_raw,
                "type": "temp",
            }

            i += 5

        # Deduplicate item names
        used = set()
        result = []
        for name in sorted(sensors.keys()):
            item = name
            idx = 0
            while item in used:
                item = "%s/%d" % (name, idx)
                idx += 1
            used.add(item)

            # Only temperature (type == "temp") is handled by this check
            if sensors[name]["type"] != "temp":
                continue

            # Suggest warn/crit from default Checkmk temperature rules
            result.append({
                "item": item,
                "params": {},
                "metrics": ["temperature"]
            })

        return {
            "changed": False,
            "msg": "discovered %d temperatures" % len(result),
            "data": {"discovery": result}
        }

    # CHECK MODE
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "item is required",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Reuse the discovery probe logic to avoid duplication (read-only)
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host] + oids, mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    lines = res.stdout.splitlines()
    sensors = {}
    i = 0
    while i < len(lines):
        if i + 4 >= len(lines):
            break

        indices = []
        values = []
        for j in range(5):
            line = lines[i + j].strip()
            eq_idx = line.find("=")
            if eq_idx == -1:
                break
            oid_part = line[:eq_idx].strip()
            val_part = line[eq_idx + 1:].strip()
            dot_idx = oid_part.rfind(".")
            if dot_idx == -1:
                break
            idx_str = oid_part[dot_idx + 1:]
            indices.append(idx_str)
            values.append(val_part)

        if len(indices) != 5 or len(set(indices)) != 1:
            i += 1
            continue

        descr_raw = values[0]
        sensortype_raw = values[1]
        value_raw = values[2]
        unit_raw = values[3]
        state_raw = values[4]

        sensortype = sensortype_raw
        for prefix in ["INTEGER: ", "Gauge32: ", "INTEGER:", "Gauge32:"]:
            if sensortype.startswith(prefix):
                sensortype = sensortype[len(prefix):]
                break

        value_clean = value_raw
        for prefix in ["INTEGER: ", "Gauge32: ", "STRING: ", "Counter32: ", "Counter64: "]:
            if value_clean.startswith(prefix):
                value_clean = value_clean[len(prefix):]
                break
        if value_clean.startswith('"') and value_clean.endswith('"'):
            value_clean = value_clean[1:-1]

        descr = descr_raw
        for prefix in ["STRING: "]:
            if descr.startswith(prefix):
                descr = descr[len(prefix):]
                break
        if descr.startswith('"') and descr.endswith('"'):
            descr = descr[1:-1]

        # Filter temperature only
        if sensortype != "0":
            i += 5
            continue

        if value_clean == "-273.15":
            i += 5
            continue

        state_map = {"0": "UNKNOWN", "1": "OK", "2": "WARN", "3": "CRIT"}
        state_str = state_raw
        for prefix in ["INTEGER: ", "Gauge32: "]:
            if state_str.startswith(prefix):
                state_str = state_str[len(prefix):]
                break
        state_val = state_map.get(state_str, "UNKNOWN")

        sensors[descr] = {
            "state": state_val,
            "value": value_clean,
            "unit": unit_raw,
            "type": "temp",
        }

        i += 5

    # Deduplicate names
    used = set()
    sensors_dedup = {}
    for name in sensors.keys():
        item_candidate = name
        idx = 0
        while item_candidate in used:
            item_candidate = "%s/%d" % (name, idx)
            idx += 1
        used.add(item_candidate)
        sensors_dedup[item_candidate] = sensors[name]

    data = sensors_dedup.get(item)
    if data == None:
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Extract numeric temperature value with guard instead of try/except
    val_str = data["value"]
    temp_value = 0.0
    if val_str.isdigit() or (val_str.startswith("-") and val_str[1:].isdigit()):
        temp_value = float(val_str)
    else:
        # Try to parse as float with basic validation
        parts = val_str.split(".")
        if len(parts) == 2:
            if parts[0].lstrip("-").isdigit() and parts[1].isdigit():
                temp_value = float(val_str)
        elif len(parts) == 1 and parts[0].lstrip("-").isdigit():
            temp_value = float(val_str)

    # Extract thresholds from params (default Checkmk temperature rules)
    # Checkmk default: no levels -> OK
    warn = None
    crit = None

    # Checkmk temperature params often use "levels" (tuple) or "unit"
    # We accept "levels" tuple or separate warn/crit keys
    if params.get("levels") != None:
        levels = params.get("levels")
        if type(levels) == "list" and len(levels) == 2:
            w = levels[0]
            c = levels[1]
            if type(w) == "int" or type(w) == "float":
                warn = float(w)
            if type(c) == "int" or type(c) == "float":
                crit = float(c)

    # Fallback keys
    if warn == None and params.get("warn") != None:
        w = params.get("warn")
        if type(w) == "int" or type(w) == "float":
            warn = float(w)
    if crit == None and params.get("crit") != None:
        c = params.get("crit")
        if type(c) == "int" or type(c) == "float":
            crit = float(c)

    # Checkmk default: no levels -> OK, but if present apply standard grading
    state = "OK"
    if warn != None and crit != None:
        # upper bounds
        if temp_value >= crit:
            state = "CRIT"
        elif temp_value >= warn:
            state = "WARN"
    elif warn != None and crit == None:
        if temp_value >= warn:
            state = "WARN"
    elif warn == None and crit != None:
        if temp_value >= crit:
            state = "CRIT"

    # Format summary message
    unit = data.get("unit", "")
    unit_clean = unit
    if unit_clean.startswith("STRING: "):
        unit_clean = unit_clean[8:]
    if unit_clean.startswith('"') and unit_clean.endswith('"'):
        unit_clean = unit_clean[1:-1]

    if unit_clean == "":
        msg = "%s %f" % (item, temp_value)
    else:
        msg = "%s %f %s" % (item, temp_value, unit_clean)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temperature": temp_value},
            "details": ""
        },
    }