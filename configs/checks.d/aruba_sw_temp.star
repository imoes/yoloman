def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.47196.4.1.1.3.11.3.1.1"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}

        entries = {}
        for line in res.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) < 2:
                continue
            oid_full = parts[0]
            value = " ".join(parts[1:]).strip()
            if value.startswith("STRING: "):
                value = value[8:].strip('"')
            # Extract sensor index from OID end (last component after the base)
            base_oid = ".1.3.6.1.4.1.47196.4.1.1.3.11.3.1.1"
            if not oid_full.startswith(base_oid):
                continue
            suffix = oid_full[len(base_oid):]
            if suffix.startswith("."):
                suffix = suffix[1:]
            if suffix.isdigit():
                idx = suffix
                entries.setdefault(idx, {})

                # OID mapping: 5=sensorName, 6=sensorState, 7=sensorTemp, 8=sensorMinTemp, 9=sensorMaxTemp
                if ".5" in oid_full:
                    entries[idx]["name"] = value
                elif ".6" in oid_full:
                    entries[idx]["status"] = value
                elif ".7" in oid_full and value.isdigit():
                    entries[idx]["cur"] = int(value) / 1000.0
                elif ".8" in oid_full and value.isdigit():
                    entries[idx]["min"] = int(value) / 1000.0
                elif ".9" in oid_full and value.isdigit():
                    entries[idx]["max"] = int(value) / 1000.0

        # Build discovered items (exclude absent status)
        out = []
        for idx, data in entries.items():
            status = data.get("status", "")
            # Checkmk: SensorStatus.absent = 3; "absent" maps to absent
            if status == "absent":
                continue
            item = data.get("name", "")
            if not item:
                continue
            out.append({"item": item, "params": {"input_unit": "c"}, "metrics": ["temp"]})

        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(out),
            "data": {"discovery": out},
        }

    # Check mode (per-item)
    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "item required", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Fetch all sensor data
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.47196.4.1.1.3.11.3.1.1"
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    entries = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) < 2:
            continue
        oid_full = parts[0]
        value = " ".join(parts[1:]).strip()
        if value.startswith("STRING: "):
            value = value[8:].strip('"')
        # Extract sensor index
        base_oid = ".1.3.6.1.4.1.47196.4.1.1.3.11.3.1.1"
        if not oid_full.startswith(base_oid):
            continue
        suffix = oid_full[len(base_oid):]
        if suffix.startswith("."):
            suffix = suffix[1:]
        if suffix.isdigit():
            idx = suffix
            entries.setdefault(idx, {})
            if ".5" in oid_full:
                entries[idx]["name"] = value
            elif ".6" in oid_full:
                entries[idx]["status"] = value
            elif ".7" in oid_full and value.isdigit():
                entries[idx]["cur"] = int(value) / 1000.0
            elif ".8" in oid_full and value.isdigit():
                entries[idx]["min"] = int(value) / 1000.0
            elif ".9" in oid_full and value.isdigit():
                entries[idx]["max"] = int(value) / 1000.0

    # Find matching sensor
    sensor = None
    for idx, data in entries.items():
        if data.get("name") == item:
            sensor = data
            break

    if sensor == None or sensor.get("status") == None:
        return {
            "changed": False,
            "msg": "sensor '%s' not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    status = sensor.get("status", "")
    cur_temp = sensor.get("cur", 0)
    min_temp = sensor.get("min", 0)
    max_temp = sensor.get("max", 0)

    # Determine defaults based on name (same logic as Checkmk)
    warn_default = 35.0
    crit_default = 40.0
    name = item.upper()
    if "CPU" in name:
        warn_default, crit_default = 80.0, 90.0
    elif "ASIC" in name:
        warn_default, crit_default = 80.0, 90.0
    elif "DDR" in name:
        if "INLET" in name:
            warn_default, crit_default = 40.0, 45.0
        else:
            warn_default, crit_default = 60.0, 70.0
    elif "INLET" in name:
        warn_default, crit_default = 30.0, 40.0
    elif "PHY" in name:
        warn_default, crit_default = 80.0, 90.0
    elif "INTERNAL" in name:
        warn_default, crit_default = 45.0, 50.0
    elif "IBC" in name:
        warn_default, crit_default = 45.0, 50.0
    elif "PCIE" in name:
        warn_default, crit_default = 55.0, 60.0
    elif "BOARD-REAR" in name or "BOARD_REAR" in name:
        warn_default, crit_default = 45.0, 50.0
    elif "EXHAUST" in name:
        warn_default, crit_default = 45.0, 50.0

    warn = params.get("warn", warn_default)
    crit = params.get("crit", crit_default)

    # Determine status-based state
    state = "UNKNOWN"
    if status == "absent":
        state = "UNKNOWN"
    elif status == "fault":
        state = "WARN"
    elif status == "warning":
        state = "WARN"
    elif status == "normal":
        state = "OK"
    elif status == "emergency":
        state = "CRIT"
    else:
        state = "UNKNOWN"

    # Temperature-based state (override if worse)
    # Checkmk uses check_temperature; we implement simple logic: CRIT >= crit, WARN >= warn
    if state in ("OK",):
        if cur_temp >= crit:
            state = "CRIT"
        elif cur_temp >= warn:
            state = "WARN"

    msg_parts = []
    msg_parts.append("Device status: %s" % status)
    if state != "UNKNOWN":
        msg_parts.append("Temperature: %f C" % cur_temp)
    msg_parts.append("Min temperature: %f C" % min_temp)
    msg_parts.append("Max temperature: %f C" % max_temp)
    msg = ", ".join(msg_parts)

    metrics = {}
    if state != "UNKNOWN":
        metrics["temp"] = cur_temp

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }
