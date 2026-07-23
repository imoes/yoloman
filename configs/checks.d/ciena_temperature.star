def _get_snmp_value(ctx, host, community, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, oid], mutates=False)
    if res.rc != 0:
        return ""
    # Parse value after last ": "
    val = res.stdout.strip()
    parts = val.rsplit(" ", 1)
    if len(parts) == 2:
        return parts[1].strip()
    return val

def _detect_ciena_5171(ctx, host, community):
    desc = _get_snmp_value(ctx, host, community, ".1.3.6.1.2.1.1.1.0")
    return "5171" in desc

def _detect_ciena_5142(ctx, host, community):
    desc = _get_snmp_value(ctx, host, community, ".1.3.6.1.2.1.1.1.0")
    return "5142" in desc

def _get_sysobjectid(ctx, host, community):
    return _get_snmp_value(ctx, host, community, ".1.3.6.1.2.1.1.2.0")

def _detect_ciena(ctx, host, community):
    objid = _get_sysobjectid(ctx, host, community)
    return objid.startswith(".1.3.6.1.4.1.1271.1.2.11") or objid.startswith(".1.3.6.1.4.1.6141.1.96")

# Mapping enums (top-level constants for state handling)
TCE_HEALTH_STATUS = {
    "1": "unknown",
    "2": "normal",
    "3": "warning",
    "4": "degraded",
    "5": "faulted",
}

LEO_TEMP_SENSOR_STATE = {
    "0": "higher_than_threshold",
    "1": "normal",
    "2": "lower_than_threshold",
}

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    if params.get("_discover"):
        # First detect which Ciena model (5171 or 5142)
        if not _detect_ciena(ctx, host, community):
            return {"changed": False, "msg": "not a Ciena 5142/5171 device",
                    "data": {"discovery": []}}

        # Determine which SNMP tree to use
        if _detect_ciena_5171(ctx, host, community):
            base_oid = ".1.3.6.1.4.1.1271.2.1.5.1.2.1.4.13.1"
        elif _detect_ciena_5142(ctx, host, community):
            base_oid = ".1.3.6.1.4.1.6141.2.60.11.1.1.5.1.1"
        else:
            return {"changed": False, "msg": "unsupported Ciena device model",
                    "data": {"discovery": []}}

        # Walk base OID to collect all sensor entries
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed: " + res.stderr,
                    "data": {"discovery": []}}

        out = []
        for line in res.stdout.splitlines():
            if not line or "=" not in line:
                continue
            # Format: ".1.3.6.1.4.1.<oid>.<end> = STRING: <value1> <value2> ..."
            parts = line.split(" = ")
            if len(parts) < 2:
                continue
            full_oid = parts[0].strip()
            value_str = parts[1].strip()
            oid_end = full_oid.rsplit(".", 1)[-1] if "." in full_oid else ""
            # Parse values
            vals = value_str.split()
            if len(vals) < 3:
                continue
            # Values: [device_status, temperature] (oid_end is index)
            device_status_str = vals[1]
            temp_str = vals[2]

            # Extract item description
            if _detect_ciena_5171(ctx, host, community):
                if "." in oid_end:
                    sensor, slot = oid_end.split(".")
                    item = "sensor " + sensor + " slot " + slot
                else:
                    continue
            else:  # 5142
                item = oid_end.strip()

            # Get device status
            if _detect_ciena_5171(ctx, host, community):
                status_name = TCE_HEALTH_STATUS.get(device_status_str, "unknown")
                dev_status = 0 if status_name == "normal" else 2
            else:  # 5142
                status_name = LEO_TEMP_SENSOR_STATE.get(device_status_str, "unknown")
                dev_status = 0 if status_name == "normal" else 2

            out.append({"item": item, "params": {}, "metrics": ["temperature"]})

        return {"changed": False, "msg": "discovered %d sensors" % len(out),
                "data": {"discovery": out}}

    # Check mode (non-discovery)
    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Determine which SNMP tree to use
    if not _detect_ciena(ctx, host, community):
        return {"changed": False, "msg": "not a Ciena 5142/5171 device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if _detect_ciena_5171(ctx, host, community):
        base_oid = ".1.3.6.1.4.1.1271.2.1.5.1.2.1.4.13.1"
        model = "5171"
    elif _detect_ciena_5142(ctx, host, community):
        base_oid = ".1.3.6.1.4.1.6141.2.60.11.1.1.5.1.1"
        model = "5142"
    else:
        return {"changed": False, "msg": "unsupported Ciena device model",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Construct full OID for this item
    # For 5171: base_oid + "." + sensor + "." + slot
    # For 5142: base_oid + "." + item (which is just sensor number)
    if model == "5171":
        # Parse item back to OID suffix: "sensor X slot Y" -> "X.Y"
        parts = item.split()
        if len(parts) < 4 or parts[0] != "sensor" or parts[2] != "slot":
            return {"changed": False, "msg": "invalid item format for Ciena 5171",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        oid_end = parts[1] + "." + parts[3]
    else:  # 5142
        oid_end = item

    full_oid = base_oid + "." + oid_end
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, full_oid], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "snmpget failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse response: "OID = STRING: sensor_status temp"
    line = res.stdout.strip()
    if "=" not in line:
        return {"changed": False, "msg": "unexpected response format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    value_str = line.split(" = ", 1)[1].strip()
    vals = value_str.split()
    if len(vals) < 3:
        return {"changed": False, "msg": "insufficient values in response",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    device_status_str = vals[1]
    temp_str = vals[2]

    # Convert temperature to integer
    if not temp_str.isdigit():
        return {"changed": False, "msg": "temperature not numeric: " + temp_str,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    temperature = int(temp_str)

    # Determine status name and device status
    if model == "5171":
        status_name = TCE_HEALTH_STATUS.get(device_status_str, "unknown")
        dev_status = 0 if status_name == "normal" else 2
    else:
        status_name = LEO_TEMP_SENSOR_STATE.get(device_status_str, "unknown")
        dev_status = 0 if status_name == "normal" else 2

    # Apply thresholds using Checkmk temperature check semantics
    # Default thresholds (no params provided in Checkmk source)
    levels = params.get("levels", (None, None))
    warn = levels[0] if levels[0] != None else 40
    crit = levels[1] if levels[1] != None else 50

    # Determine state based on thresholds
    state = "OK"
    if crit != None and temperature >= crit:
        state = "CRIT"
    elif warn != None and temperature >= warn:
        state = "WARN"

    # Build message
    msg = "Sensor: %s, Temp: %d C, Status: %s" % (item, temperature, status_name)

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"temperature": temperature}, "details": ""}}
