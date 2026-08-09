# ===== Starlark check: didactum_sensors_analog =====

def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)


# ===== discovery =====
def _discover(ctx, params):
    snmp_res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.46501.5.2.1"
    ], mutates=False)
    if snmp_res.rc != 0 or not snmp_res.stdout:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"discovery": []}
        }

    lines = snmp_res.stdout.splitlines()
    # Collect sensor data in a single pass
    sensor_data_map = {}  # sensor_id -> {type, status, value, levels, levels_lower}
    
    for line in lines:
        if not line or " = " not in line:
            continue
        # Parse OID and value
        parts = line.split(" = ", 1)
        oid_part = parts[0]
        value_part = parts[1]
        if ":" in value_part:
            value_str = value_part.split(":", 1)[1].strip().strip('"')
        else:
            value_str = value_part.strip()

        oid_end = oid_part.rsplit(".", 1)
        if len(oid_end) != 2:
            continue
        oid_suffix = oid_end[1]
        if not oid_suffix.isdigit():
            continue

        base_oid = oid_end[0]
        if not base_oid.endswith(".5") and not base_oid.endswith(".6") and not base_oid.endswith(".7") and not base_oid.endswith(".10") and not base_oid.endswith(".11") and not base_oid.endswith(".12") and not base_oid.endswith(".13"):
            continue

        # Extract sensor ID (last number after last dot)
        sensor_id = oid_suffix

        # Determine field type from base OID suffix
        field_type = ""
        if base_oid.endswith(".5"):
            field_type = "name"
        elif base_oid.endswith(".6"):
            field_type = "status"
        elif base_oid.endswith(".7"):
            field_type = "value"
        elif base_oid.endswith(".10"):
            field_type = "low_alarm"
        elif base_oid.endswith(".11"):
            field_type = "low_warn"
        elif base_oid.endswith(".12"):
            field_type = "high_warn"
        elif base_oid.endswith(".13"):
            field_type = "high_alarm"

        if field_type == "name":
            # Initialize sensor entry
            if not sensor_id in sensor_data_map:
                sensor_data_map[sensor_id] = {"id": sensor_id}
            sensor_data_map[sensor_id]["name"] = value_str
        elif field_type == "status":
            if sensor_id in sensor_data_map:
                sensor_data_map[sensor_id]["status"] = value_str
        elif field_type == "value":
            if sensor_id in sensor_data_map:
                sensor_data_map[sensor_id]["value"] = value_str
        elif field_type == "low_alarm":
            if sensor_id in sensor_data_map:
                sensor_data_map[sensor_id]["low_alarm"] = value_str
        elif field_type == "low_warn":
            if sensor_id in sensor_data_map:
                sensor_data_map[sensor_id]["low_warn"] = value_str
        elif field_type == "high_warn":
            if sensor_id in sensor_data_map:
                sensor_data_map[sensor_id]["high_warn"] = value_str
        elif field_type == "high_alarm":
            if sensor_id in sensor_data_map:
                sensor_data_map[sensor_id]["high_alarm"] = value_str

    # Build discovery result
    discovery = []
    for sensor_id, data in sensor_data_map.items():
        name = data.get("name")
        status = data.get("status")
        value = data.get("value")
        if not name or status == None or value == None:
            continue

        if status in ("off", "not connected"):
            continue

        # Determine sensor type based on name
        sensor_type = "temperature"
        if "voltage" in name.lower() or "dc" in name.lower():
            sensor_type = "voltage"
        elif "humidity" in name.lower():
            sensor_type = "humidity"

        metrics = []
        if sensor_type == "temperature":
            metrics = ["temp"]
        elif sensor_type == "humidity":
            metrics = ["humidity"]
        elif sensor_type == "voltage":
            metrics = ["voltage"]

        suggested_params = {}
        if sensor_type == "temperature":
            # Parse numeric thresholds if available
            high_warn = 45.0
            high_alarm = 50.0
            low_warn = 5.0
            low_alarm = 0.0
            if data.get("high_warn"):
                v = data["high_warn"]
                high_warn = float(v) if v.replace(".", "").replace("-", "").isdigit() or v.replace(".", "").replace("-", "").isdigit() else 45.0
            if data.get("high_alarm"):
                v = data["high_alarm"]
                high_alarm = float(v) if v.replace(".", "").replace("-", "").isdigit() or v.replace(".", "").replace("-", "").isdigit() else 50.0
            if data.get("low_warn"):
                v = data["low_warn"]
                low_warn = float(v) if v.replace(".", "").replace("-", "").isdigit() or v.replace(".", "").replace("-", "").isdigit() else 5.0
            if data.get("low_alarm"):
                v = data["low_alarm"]
                low_alarm = float(v) if v.replace(".", "").replace("-", "").isdigit() or v.replace(".", "").replace("-", "").isdigit() else 0.0
            suggested_params = {
                "levels": (high_warn, high_alarm),
                "levels_lower": (low_warn, low_alarm)
            }
        elif sensor_type == "humidity":
            suggested_params = {
                "levels": (70.0, 80.0),
                "levels_lower": (20.0, 10.0)
            }

        discovery.append({
            "item": name,
            "params": suggested_params,
            "metrics": metrics
        })

    return {
        "changed": False,
        "msg": "discovered %d sensors" % len(discovery),
        "data": {"discovery": discovery}
    }


# ===== check =====
def _check(ctx, params):
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Get SNMP data
    snmp_res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.46501.5.2.1"
    ], mutates=False)

    if snmp_res.rc != 0 or not snmp_res.stdout:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse SNMP output and find the item
    sensor_data = None
    lines = snmp_res.stdout.splitlines()
    # Reuse the same data map approach for consistency
    sensor_data_map = {}  # sensor_id -> {type, status, value, levels, levels_lower}

    for line in lines:
        if not line or " = " not in line:
            continue
        parts = line.split(" = ", 1)
        oid_part = parts[0]
        value_part = parts[1]
        if ":" in value_part:
            value_str = value_part.split(":", 1)[1].strip().strip('"')
        else:
            value_str = value_part.strip()

        oid_end = oid_part.rsplit(".", 1)
        if len(oid_end) != 2:
            continue
        oid_suffix = oid_end[1]
        if not oid_suffix.isdigit():
            continue

        base_oid = oid_end[0]
        if not base_oid.endswith(".5") and not base_oid.endswith(".6") and not base_oid.endswith(".7") and not base_oid.endswith(".10") and not base_oid.endswith(".11") and not base_oid.endswith(".12") and not base_oid.endswith(".13"):
            continue

        # Extract sensor ID (last number after last dot)
        sensor_id = oid_suffix

        # Determine field type from base OID suffix
        field_type = ""
        if base_oid.endswith(".5"):
            field_type = "name"
        elif base_oid.endswith(".6"):
            field_type = "status"
        elif base_oid.endswith(".7"):
            field_type = "value"
        elif base_oid.endswith(".10"):
            field_type = "low_alarm"
        elif base_oid.endswith(".11"):
            field_type = "low_warn"
        elif base_oid.endswith(".12"):
            field_type = "high_warn"
        elif base_oid.endswith(".13"):
            field_type = "high_alarm"

        if field_type == "name":
            # Initialize sensor entry
            if not sensor_id in sensor_data_map:
                sensor_data_map[sensor_id] = {"id": sensor_id}
            sensor_data_map[sensor_id]["name"] = value_str
        elif field_type == "status":
            if sensor_id in sensor_data_map:
                sensor_data_map[sensor_id]["status"] = value_str
        elif field_type == "value":
            if sensor_id in sensor_data_map:
                sensor_data_map[sensor_id]["value"] = value_str
        elif field_type == "low_alarm":
            if sensor_id in sensor_data_map:
                sensor_data_map[sensor_id]["low_alarm"] = value_str
        elif field_type == "low_warn":
            if sensor_id in sensor_data_map:
                sensor_data_map[sensor_id]["low_warn"] = value_str
        elif field_type == "high_warn":
            if sensor_id in sensor_data_map:
                sensor_data_map[sensor_id]["high_warn"] = value_str
        elif field_type == "high_alarm":
            if sensor_id in sensor_data_map:
                sensor_data_map[sensor_id]["high_alarm"] = value_str

    # Find the requested item
    for sensor_id, data in sensor_data_map.items():
        name = data.get("name")
        if name == item:
            status = data.get("status")
            value = data.get("value")
            if status == None or value == None:
                continue
            # Determine sensor type based on name
            sensor_type = "temperature"
            if "voltage" in name.lower() or "dc" in name.lower():
                sensor_type = "voltage"
            elif "humidity" in name.lower():
                sensor_type = "humidity"
            sensor_data = {
                "status": status,
                "value": value,
                "type": sensor_type,
                "high_warn": data.get("high_warn"),
                "high_alarm": data.get("high_alarm"),
                "low_warn": data.get("low_warn"),
                "low_alarm": data.get("low_alarm")
            }
            break

    if sensor_data == None:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Convert values
    value = 0.0
    v_str = sensor_data["value"]
    if v_str.replace(".", "").replace("-", "").isdigit() or v_str.replace(".", "").replace("-", "").isdigit():
        value = float(v_str)

    # Extract levels from params
    warn = None
    crit = None
    warn_lower = None
    crit_lower = None

    levels = params.get("levels")
    levels_lower = params.get("levels_lower")
    if levels and len(levels) == 2:
        warn, crit = levels
    if levels_lower and len(levels_lower) == 2:
        warn_lower, crit_lower = levels_lower

    # Use sensor's own levels if available
    if sensor_data.get("high_warn"):
        v = sensor_data["high_warn"]
        if v.replace(".", "").replace("-", "").isdigit() or v.replace(".", "").replace("-", "").isdigit():
            warn = float(v)
    if sensor_data.get("high_alarm"):
        v = sensor_data["high_alarm"]
        if v.replace(".", "").replace("-", "").isdigit() or v.replace(".", "").replace("-", "").isdigit():
            crit = float(v)
    if sensor_data.get("low_warn"):
        v = sensor_data["low_warn"]
        if v.replace(".", "").replace("-", "").isdigit() or v.replace(".", "").replace("-", "").isdigit():
            warn_lower = float(v)
    if sensor_data.get("low_alarm"):
        v = sensor_data["low_alarm"]
        if v.replace(".", "").replace("-", "").isdigit() or v.replace(".", "").replace("-", "").isdigit():
            crit_lower = float(v)

    # Determine state
    state = "OK"
    if sensor_data["status"] == "alarm" or sensor_data["status"] == "high alarm" or sensor_data["status"] == "low alarm":
        state = "CRIT"
    elif sensor_data["status"] == "warning" or sensor_data["status"] == "high warning" or sensor_data["status"] == "low warning":
        state = "WARN"
    elif sensor_data["status"] == "not connected":
        state = "UNKNOWN"
    else:
        # Check against numeric thresholds if status is "normal" or similar
        if warn != None and value >= warn:
            state = "WARN"
        if crit != None and value >= crit:
            state = "CRIT"
        if warn_lower != None and value <= warn_lower:
            state = "WARN"
        if crit_lower != None and value <= crit_lower:
            state = "CRIT"

    # Build metrics
    metrics = {}
    if sensor_data["type"] == "temperature":
        metrics["temp"] = value
    elif sensor_data["type"] == "humidity":
        metrics["humidity"] = value
    elif sensor_data["type"] == "voltage":
        metrics["voltage"] = value

    # Build message
    msg = "%s: %s" % (item, sensor_data["status"])
    if sensor_data["type"] == "temperature":
        msg = "%s: %f C" % (item, value)
    elif sensor_data["type"] == "humidity":
        msg = "%s: %f %%rH" % (item, value)
    elif sensor_data["type"] == "voltage":
        msg = "%s: %f V" % (item, value)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }
