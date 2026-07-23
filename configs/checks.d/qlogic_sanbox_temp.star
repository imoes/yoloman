def main(ctx, params):
    # SNMP base OID for qlogic_sanbox temperature section
    SNMP_BASE_OID = ".1.3.6.1.3.94.1.8.1"
    OID_TEMP_TYPE = "8"
    OID_CHAR_TEMP = "3"

    # Status mapping: index matches SNMP value (0-based list, SNMP values start at 0)
    status_map = [
        "undefined",  # 0
        "unknown",    # 1
        "other",      # 2
        "ok",         # 3
        "warning",    # 4
        "failed",     # 5
    ]

    def status_to_state(status_int):
        if status_int == 3:
            return "OK"
        elif status_int == 4:
            return "WARN"
        elif status_int == 5:
            return "CRIT"
        else:
            return "UNKNOWN"

    def clean_sensor_id(sensor_id):
        return sensor_id.replace("16.0.0.192.221.48.", "").replace(".0.0.0.0.0.0.0.0", "")

    # ===== DISCOVERY MODE =====
    if params.get("_discover"):
        # Walk the SNMP section for qlogic_sanbox
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            SNMP_BASE_OID,
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}

        # Parse table: collect rows by sensor ID and column
        raw_data = {}
        for line in res.stdout.splitlines():
            idx = line.find(" = ")
            if idx == -1:
                continue
            oid_full = line[:idx].strip()
            value = line[idx+3:].strip().strip('"')
            suffix = oid_full[len(SNMP_BASE_OID):]
            if not suffix.startswith("."):
                continue
            suffix = suffix[1:]
            parts = suffix.split(".")
            if len(parts) < 2:
                continue
            if not parts[0].isdigit():
                continue
            col = int(parts[0])
            # Count trailing zeros
            zero_count = 0
            for p in reversed(parts):
                if p == "0":
                    zero_count += 1
                else:
                    break
            if zero_count < 8:
                continue
            id_parts = parts[1:-zero_count]
            if len(id_parts) == 0:
                continue
            sensor_id = ".".join(id_parts)
            # Store column data
            if sensor_id not in raw_data:
                raw_data[sensor_id] = {}
            raw_data[sensor_id][col] = value

        # Build discovered items
        items = []
        for sensor_id, cols in raw_data.items():
            sensor_type = cols.get(7, "")
            sensor_char = cols.get(8, "")
            sensor_name = cols.get(3, "")

            if sensor_type == OID_TEMP_TYPE and sensor_char == OID_CHAR_TEMP and sensor_name != "Temperature Status":
                cleaned_id = clean_sensor_id(sensor_id)
                items.append({
                    "item": cleaned_id,
                    "params": {},
                    "metrics": ["temp"]
                })

        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(items),
            "data": {"discovery": items},
        }

    # ===== CHECK MODE =====
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        SNMP_BASE_OID,
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse table
    raw_data = {}
    for line in res.stdout.splitlines():
        idx = line.find(" = ")
        if idx == -1:
            continue
        oid_full = line[:idx].strip()
        value = line[idx+3:].strip().strip('"')
        suffix = oid_full[len(SNMP_BASE_OID):]
        if not suffix.startswith("."):
            continue
        suffix = suffix[1:]
        parts = suffix.split(".")
        if len(parts) < 2:
            continue
        if not parts[0].isdigit():
            continue
        col = int(parts[0])
        zero_count = 0
        for p in reversed(parts):
            if p == "0":
                zero_count += 1
            else:
                break
        if zero_count < 8:
            continue
        id_parts = parts[1:-zero_count]
        if len(id_parts) == 0:
            continue
        sensor_id = ".".join(id_parts)
        if sensor_id not in raw_data:
            raw_data[sensor_id] = {}
        raw_data[sensor_id][col] = value

    # Find matching item
    found = False
    for sensor_id, cols in raw_data.items():
        cleaned_id = clean_sensor_id(sensor_id)
        if cleaned_id != item:
            continue
        found = True

        sensor_status_raw = cols.get(4, "")
        sensor_message = cols.get(6, "")
        sensor_type = cols.get(7, "")

        # Only process temperature sensors
        if sensor_type != OID_TEMP_TYPE:
            return {
                "changed": False,
                "msg": "item %s not found or not a temperature sensor" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }

        # Parse status safely
        sensor_status = 1
        if sensor_status_raw.isdigit() or (len(sensor_status_raw) > 1 and sensor_status_raw[0] == '-' and sensor_status_raw[1:].isdigit()):
            sensor_status = int(sensor_status_raw)
        else:
            sensor_status = 1

        status_str = status_map[sensor_status] if (0 <= sensor_status) and (sensor_status < len(status_map)) else str(sensor_status)
        state = status_to_state(sensor_status)

        # Parse temperature if present
        metrics = {}
        summary_parts = []
        summary_parts.append("Sensor %s is at %s and reports status %s" % (item, sensor_message, status_str))
        if sensor_message.endswith(" degrees C"):
            temp_part = sensor_message.replace(" degrees C", "")
            if temp_part.lstrip("-").isdigit():
                temp_val = float(temp_part)
                metrics["temp"] = temp_val

        return {
            "changed": False,
            "msg": ", ".join(summary_parts),
            "data": {
                "state": state,
                "metrics": metrics,
                "details": ""
            }
        }

    # Not found
    return {
        "changed": False,
        "msg": "No sensor %s found" % item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
    }