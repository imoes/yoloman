def main(ctx, params):
    # Constants for SNMP OIDs (from the Checkmk plugin)
    OID_BASE = ".1.3.6.1.4.1.2544"
    OID_RAW_TEMP = OID_BASE + ".1.11.2.4.2.1.1.1"
    OID_RAW_HIGH = OID_BASE + ".1.11.2.4.2.1.1.2"
    OID_RAW_LOW = OID_BASE + ".1.11.2.4.2.1.1.3"
    OID_DESCRIPTION = OID_BASE + ".2.5.5.1.1.1"
    OID_NAME = OID_BASE + ".2.5.5.2.1.5"

    # Helper: parse a single OID value from snmpwalk output
    # Expected format: "OID = INTEGER: value" or "OID = STRING: value"
    def get_oid_values(output, base_oid):
        result = {}
        for line in output.splitlines():
            line = line.strip()
            if not line:
                continue
            # Split into OID part and value part
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            full_oid = parts[0].strip()
            value_part = parts[1].strip()
            # Extract value after colon for type-prefixed values
            if value_part.startswith("INTEGER:"):
                value = value_part[8:].strip()
            elif value_part.startswith("STRING:"):
                # Strip quotes if present
                val_str = value_part[7:].strip()
                value = val_str.strip('"')
            else:
                value = value_part
            # Only keep entries under our base OID
            if full_oid.startswith(base_oid):
                # Extract index (last number after final dot)
                suffix = full_oid[len(base_oid):].lstrip('.')
                index = suffix.split('.')[-1] if '.' in suffix else suffix
                result[index] = value
        return result

    if params.get("_discover"):
        # Discovery: get all needed SNMP data
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            OID_RAW_TEMP, OID_RAW_HIGH, OID_RAW_LOW, OID_DESCRIPTION, OID_NAME
        ], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}

        # Parse into per-sensor data
        raw_temps = get_oid_values(res.stdout, OID_RAW_TEMP)
        raw_highs = get_oid_values(res.stdout, OID_RAW_HIGH)
        raw_lows = get_oid_values(res.stdout, OID_RAW_LOW)
        descriptions = get_oid_values(res.stdout, OID_DESCRIPTION)
        names = get_oid_values(res.stdout, OID_NAME)

        # Merge by index
        sensors = {}
        all_indices = []
        for k in raw_temps:
            if not k in all_indices:
                all_indices.append(k)
        for k in raw_highs:
            if not k in all_indices:
                all_indices.append(k)
        for k in raw_lows:
            if not k in all_indices:
                all_indices.append(k)
        for k in names:
            if not k in all_indices:
                all_indices.append(k)
        for idx in all_indices:
            raw_temp = raw_temps.get(idx, "")
            raw_high = raw_highs.get(idx, "")
            raw_low = raw_lows.get(idx, "")
            description = descriptions.get(idx, "")
            name = names.get(idx, "")

            # Check if connected (non-empty description and raw_temp)
            if not description or not raw_temp:
                continue
            # Try to parse values — guard instead of try/except
            if raw_temp.isdigit() or (raw_temp.startswith("-") and raw_temp[1:].isdigit()):
                temp = float(raw_temp) / 10.0
            else:
                continue
            if raw_high.isdigit() or (raw_high.startswith("-") and raw_high[1:].isdigit()):
                high = float(raw_high) / 10.0
            else:
                continue
            if raw_low.isdigit() or (raw_low.startswith("-") and raw_low[1:].isdigit()):
                low = float(raw_low) / 10.0
            else:
                continue

            # Only include if temperature > -273.0 (valid sensor)
            if temp > -273.0 and name:
                sensors[name] = {"temp": temp, "high": high, "low": low}

        # Build discovery result
        items = []
        for name, data in sensors.items():
            items.append({
                "item": name,
                "params": {},
                "metrics": ["temperature"]
            })
        return {"changed": False, "msg": "discovered %d sensors" % len(items), "data": {"discovery": items}}

    # Check mode (one item)
    item = params.get("item", "")
    # Re-run discovery to get current sensor data (same as above)
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        OID_RAW_TEMP, OID_RAW_HIGH, OID_RAW_LOW, OID_DESCRIPTION, OID_NAME
    ], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "SNMP walk failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw_temps = get_oid_values(res.stdout, OID_RAW_TEMP)
    raw_highs = get_oid_values(res.stdout, OID_RAW_HIGH)
    raw_lows = get_oid_values(res.stdout, OID_RAW_LOW)
    descriptions = get_oid_values(res.stdout, OID_DESCRIPTION)
    names = get_oid_values(res.stdout, OID_NAME)

    # Merge by index
    sensors = {}
    all_indices = []
    for k in raw_temps:
        if not k in all_indices:
            all_indices.append(k)
    for k in raw_highs:
        if not k in all_indices:
            all_indices.append(k)
    for k in raw_lows:
        if not k in all_indices:
            all_indices.append(k)
    for k in names:
        if not k in all_indices:
            all_indices.append(k)
    for idx in all_indices:
        raw_temp = raw_temps.get(idx, "")
        raw_high = raw_highs.get(idx, "")
        raw_low = raw_lows.get(idx, "")
        description = descriptions.get(idx, "")
        name = names.get(idx, "")

        if not description or not raw_temp:
            continue
        if raw_temp.isdigit() or (raw_temp.startswith("-") and raw_temp[1:].isdigit()):
            temp = float(raw_temp) / 10.0
        else:
            continue
        if raw_high.isdigit() or (raw_high.startswith("-") and raw_high[1:].isdigit()):
            high = float(raw_high) / 10.0
        else:
            continue
        if raw_low.isdigit() or (raw_low.startswith("-") and raw_low[1:].isdigit()):
            low = float(raw_low) / 10.0
        else:
            continue

        if temp > -273.0 and name:
            sensors[name] = {"temp": temp, "high": high, "low": low}

    # Find the requested item
    if not item in sensors:
        return {"changed": False, "msg": "sensor '%s' not found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sensor = sensors[item]
    temp = sensor["temp"]
    high = sensor["high"]
    low = sensor["low"]

    # Invalid sensor data?
    if temp <= -273.0:
        return {"changed": False, "msg": "Invalid sensor data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Extract thresholds from params or use Checkmk defaults
    warn_upper = params.get("levels_upper_warn", 25)
    crit_upper = params.get("levels_upper_crit", 40)
    warn_lower = params.get("levels_lower_warn", -10)
    crit_lower = params.get("levels_lower_crit", -20)

    # Apply thresholds
    state = "OK"

    # Upper bounds
    if temp >= crit_upper:
        state = "CRIT"
    elif temp >= warn_upper:
        state = "WARN"

    # Lower bounds
    if state == "OK" and temp <= crit_lower:
        state = "CRIT"
    elif state == "OK" and temp <= warn_lower:
        state = "WARN"

    return {"changed": False, "msg": "Temperature %f C" % temp, "data": {"state": state, "metrics": {"temperature": temp}, "details": ""}}
