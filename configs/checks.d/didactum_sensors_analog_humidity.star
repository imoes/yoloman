def main(ctx, params):
    # Base OID for analog sensors section
    base_oid = ".1.3.6.1.4.1.46501.5.2.1"
    
    def walk_oid(oid):
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"), oid], mutates=False)
        if res.rc != 0:
            return []
        lines = res.stdout.splitlines()
        result = []
        for line in lines:
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            full_oid, value = parts
            value = value.strip()
            result.append((full_oid, value))
        return result

    # Collect all data in discovery mode
    if params.get("_discover"):
        # Fetch all 8 columns
        type_oid = "%s.4" % base_oid
        name_oid = "%s.5" % base_oid
        state_oid = "%s.6" % base_oid
        value_oid = "%s.7" % base_oid
        low_alarm_oid = "%s.10" % base_oid
        low_warn_oid = "%s.11" % base_oid
        high_warn_oid = "%s.12" % base_oid
        high_alarm_oid = "%s.13" % base_oid

        type_data = {}
        name_data = {}
        state_data = {}
        value_data = {}
        low_alarm_data = {}
        low_warn_data = {}
        high_warn_data = {}
        high_alarm_data = {}

        for oid, storage in [(type_oid, type_data), (name_oid, name_data),
                             (state_oid, state_data), (value_oid, value_data),
                             (low_alarm_oid, low_alarm_data),
                             (low_warn_oid, low_warn_data),
                             (high_warn_oid, high_warn_data),
                             (high_alarm_oid, high_alarm_data)]:
            for full_oid, value in walk_oid(oid):
                idx = full_oid.rsplit(".", 1)[-1]
                storage[idx] = value

        # Build sections by matching names and extracting sensor data
        humidity_sensors = {}
        for name_idx, name in name_data.items():
            if name_idx not in type_data:
                continue
            sensor_type = type_data[name_idx]
            if sensor_type != "humidity":
                continue

            if name_idx not in state_data:
                continue
            state = state_data[name_idx]

            value = 0.0
            if name_idx in value_data:
                value_str = value_data[name_idx]
                if value_str.isdigit():
                    value = int(value_str)
                else:
                    value = 0.0

            low_alarm = 0.0
            low_warn = 0.0
            high_warn = 100.0
            high_alarm = 100.0
            if name_idx in low_alarm_data:
                val = low_alarm_data[name_idx]
                if val.isdigit():
                    low_alarm = int(val)
                else:
                    low_alarm = 0.0
            if name_idx in low_warn_data:
                val = low_warn_data[name_idx]
                if val.isdigit():
                    low_warn = int(val)
                else:
                    low_warn = 0.0
            if name_idx in high_warn_data:
                val = high_warn_data[name_idx]
                if val.isdigit():
                    high_warn = int(val)
                else:
                    high_warn = 100.0
            if name_idx in high_alarm_data:
                val = high_alarm_data[name_idx]
                if val.isdigit():
                    high_alarm = int(val)
                else:
                    high_alarm = 100.0

            humidity_sensors[name] = {
                "state": state,
                "value": value,
                "levels": (high_warn, high_alarm),
                "levels_lower": (low_warn, low_alarm)
            }

        # Build discovery result
        out = []
        for item in humidity_sensors:
            data = humidity_sensors[item]
            if data["state"] in ("off", "not connected"):
                continue
            out.append({
                "item": item,
                "params": {},
                "metrics": ["humidity"]
            })

        return {
            "changed": False,
            "msg": "discovered %d humidity sensors" % len(out),
            "data": {"discovery": out}
        }

    # Check mode: verify single humidity sensor
    item = params.get("item", "")
    
    # Re-fetch data for the check
    type_oid = "%s.4" % base_oid
    name_oid = "%s.5" % base_oid
    state_oid = "%s.6" % base_oid
    value_oid = "%s.7" % base_oid
    low_alarm_oid = "%s.10" % base_oid
    low_warn_oid = "%s.11" % base_oid
    high_warn_oid = "%s.12" % base_oid
    high_alarm_oid = "%s.13" % base_oid

    type_data = {}
    name_data = {}
    state_data = {}
    value_data = {}
    low_alarm_data = {}
    low_warn_data = {}
    high_warn_data = {}
    high_alarm_data = {}

    for oid, storage in [(type_oid, type_data), (name_oid, name_data),
                         (state_oid, state_data), (value_oid, value_data),
                         (low_alarm_oid, low_alarm_data),
                         (low_warn_oid, low_warn_data),
                         (high_warn_oid, high_warn_data),
                         (high_alarm_oid, high_alarm_data)]:
        for full_oid, value in walk_oid(oid):
            idx = full_oid.rsplit(".", 1)[-1]
            storage[idx] = value

    humidity_sensors = {}
    for name_idx, name in name_data.items():
        if name_idx not in type_data:
            continue
        sensor_type = type_data[name_idx]
        if sensor_type != "humidity":
            continue

        if name_idx not in state_data:
            continue
        state = state_data[name_idx]

        value = 0.0
        if name_idx in value_data:
            value_str = value_data[name_idx]
            if value_str.isdigit():
                value = int(value_str)
            else:
                value = 0.0

        low_alarm = 0.0
        low_warn = 0.0
        high_warn = 100.0
        high_alarm = 100.0
        if name_idx in low_alarm_data:
            val = low_alarm_data[name_idx]
            if val.isdigit():
                low_alarm = int(val)
            else:
                low_alarm = 0.0
        if name_idx in low_warn_data:
            val = low_warn_data[name_idx]
            if val.isdigit():
                low_warn = int(val)
            else:
                low_warn = 0.0
        if name_idx in high_warn_data:
            val = high_warn_data[name_idx]
            if val.isdigit():
                high_warn = int(val)
            else:
                high_warn = 100.0
        if name_idx in high_alarm_data:
            val = high_alarm_data[name_idx]
            if val.isdigit():
                high_alarm = int(val)
            else:
                high_alarm = 100.0

        humidity_sensors[name] = {
            "state": state,
            "value": value,
            "levels": (high_warn, high_alarm),
            "levels_lower": (low_warn, low_alarm)
        }

    data = humidity_sensors.get(item)
    if data == None:
        return {
            "changed": False,
            "msg": "no such humidity sensor: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Process humidity level logic
    humidity_value = data["value"]
    levels = data["levels"]
    levels_lower = data["levels_lower"]
    warn_upper = levels[0] if levels and len(levels) >= 2 else 70.0
    crit_upper = levels[1] if levels and len(levels) >= 2 else 80.0
    warn_lower = levels_lower[0] if levels_lower and len(levels_lower) >= 2 else 20.0
    crit_lower = levels_lower[1] if levels_lower and len(levels_lower) >= 2 else 10.0

    # Check status: high levels
    state = "OK"
    if crit_upper != None and humidity_value >= crit_upper:
        state = "CRIT"
    elif warn_upper != None and humidity_value >= warn_upper:
        state = "WARN"
    elif crit_lower != None and humidity_value <= crit_lower:
        state = "CRIT"
    elif warn_lower != None and humidity_value <= warn_lower:
        state = "WARN"

    # Map status text to Checkmk state if present
    status_text = data["state"]
    if status_text == "normal":
        state = "OK"
    elif status_text in ("alarm", "high alarm", "low alarm"):
        state = "CRIT"
    elif status_text in ("warning", "high warning", "low warning"):
        state = "WARN"
    elif status_text == "not connected":
        state = "UNKNOWN"

    # Build message and metrics
    msg = "Humidity: %f %% " % humidity_value
    metrics = {"humidity": humidity_value}

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": ""}
    }
