def main(ctx, params):
    base_oid = ".1.3.6.1.4.1.46501.5.2.1"
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On", host,
            base_oid
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}

        lines = res.stdout.splitlines()
        sensors = {}
        for line in lines:
            line = line.strip()
            if not line:
                continue
            parts = line.split(" = ")
            if len(parts) != 2:
                continue
            oid_str, val_str = parts
            oid_parts = oid_str.lstrip(".").split(".")
            if len(oid_parts) < 5:
                continue
            section_id = oid_parts[4]
            sensor_id = oid_parts[5]
            section_map = {
                "4": "name",
                "5": "state",
                "6": "state_readable",
                "7": "value",
                "10": "low_alarm",
                "11": "low_warn",
                "12": "warn",
                "13": "crit"
            }
            section_name = section_map.get(section_id)
            if not section_name:
                continue
            val = val_str.split(": ", 1)[-1].strip().strip('"')
            if sensor_id not in sensors:
                sensors[sensor_id] = {}
            sensors[sensor_id][section_name] = val

        discovered = []
        for sensor_id, attrs in sensors.items():
            name = attrs.get("name", "")
            is_voltage = False
            if name.lower().find("voltage") != -1:
                is_voltage = True
            else:
                value_str = attrs.get("value", "0")
                value_digits = value_str.replace(".", "").replace("-", "")
                if value_digits.isdigit() and value_str.find(".") == -1:
                    is_voltage = True
                elif value_str.find(".") != -1 and value_digits.isdigit():
                    dot_pos = value_str.find(".")
                    if dot_pos > 0 and dot_pos < len(value_str) - 1:
                        is_voltage = True

            if is_voltage:
                state_readable = attrs.get("state_readable", attrs.get("state", "normal"))
                value_str = attrs.get("value", "0")
                value = 0.0
                if value_str.replace(".", "").replace("-", "").isdigit() and value_str.find(".") != -1:
                    dot_pos = value_str.find(".")
                    if dot_pos > 0 and dot_pos < len(value_str) - 1:
                        value = float(value_str)
                elif value_str.replace(".", "").replace("-", "").isdigit() and value_str.find(".") == -1:
                    value = float(value_str)

                levels = None
                levels_lower = None
                if "warn" in attrs and "crit" in attrs and attrs["warn"].replace(".", "").replace("-", "").isdigit() and attrs["crit"].replace(".", "").replace("-", "").isdigit():
                    warn_val = float(attrs["warn"])
                    crit_val = float(attrs["crit"])
                    levels = (warn_val, crit_val)
                if "low_warn" in attrs and "low_alarm" in attrs and attrs["low_warn"].replace(".", "").replace("-", "").isdigit() and attrs["low_alarm"].replace(".", "").replace("-", "").isdigit():
                    low_warn_val = float(attrs["low_warn"])
                    low_crit_val = float(attrs["low_alarm"])
                    levels_lower = (low_warn_val, low_crit_val)

                suggested = {}
                if levels:
                    suggested["levels_upper"] = levels
                if levels_lower:
                    suggested["levels_lower"] = levels_lower
                suggested["state"] = "normal"

                discovered.append({
                    "item": name,
                    "params": suggested,
                    "metrics": ["voltage"]
                })

        return {
            "changed": False,
            "msg": "discovered %d voltage sensors" % len(discovered),
            "data": {"discovery": discovered}
        }

    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On", host,
        base_oid
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    lines = res.stdout.splitlines()
    sensors = {}
    for line in lines:
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        oid_str, val_str = parts
        oid_parts = oid_str.lstrip(".").split(".")
        if len(oid_parts) < 5:
            continue
        section_id = oid_parts[4]
        sensor_id = oid_parts[5]
        section_map = {
            "4": "name",
            "5": "state",
            "6": "state_readable",
            "7": "value",
            "10": "low_alarm",
            "11": "low_warn",
            "12": "warn",
            "13": "crit"
        }
        section_name = section_map.get(section_id)
        if not section_name:
            continue
        val = val_str.split(": ", 1)[-1].strip().strip('"')
        if sensor_id not in sensors:
            sensors[sensor_id] = {}
        sensors[sensor_id][section_name] = val

    data = None
    for sensor_id, attrs in sensors.items():
        if attrs.get("name") == item:
            data = attrs
            break

    if data == None:
        return {
            "changed": False,
            "msg": "sensor not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    value_str = data.get("value", "0")
    voltage = 0.0
    if value_str.replace(".", "").replace("-", "").isdigit() and value_str.find(".") == -1:
        voltage = float(value_str)
    elif value_str.replace(".", "").replace("-", "").isdigit() and value_str.find(".") != -1:
        dot_pos = value_str.find(".")
        if dot_pos > 0 and dot_pos < len(value_str) - 1:
            voltage = float(value_str)

    state_readable = data.get("state_readable", data.get("state", "normal"))

    state_map = {
        "normal": "OK",
        "alarm": "CRIT",
        "high alarm": "CRIT",
        "low alarm": "CRIT",
        "warning": "WARN",
        "high warning": "WARN",
        "low warning": "WARN",
        "not connected": "UNKNOWN",
        "off": "UNKNOWN",
        "on": "OK"
    }
    state = state_map.get(state_readable, "UNKNOWN")

    levels = None
    levels_lower = None
    if "warn" in data and "crit" in data and data["warn"].replace(".", "").replace("-", "").isdigit() and data["crit"].replace(".", "").replace("-", "").isdigit():
        levels = (float(data["warn"]), float(data["crit"]))
    if "low_warn" in data and "low_alarm" in data and data["low_warn"].replace(".", "").replace("-", "").isdigit() and data["low_alarm"].replace(".", "").replace("-", "").isdigit():
        levels_lower = (float(data["low_warn"]), float(data["low_alarm"]))

    warn = None
    crit = None
    if params.get("levels_upper"):
        warn = params["levels_upper"][0]
        crit = params["levels_upper"][1]
    elif levels:
        warn = levels[0]
        crit = levels[1]

    low_warn = None
    low_crit = None
    if levels_lower:
        low_warn = levels_lower[0]
        low_crit = levels_lower[1]

    if crit != None and voltage >= crit:
        state = "CRIT"
    elif warn != None and voltage >= warn:
        state = "WARN"

    if low_crit != None and voltage <= low_crit:
        state = "CRIT"
    elif low_warn != None and voltage <= low_warn:
        state = "WARN"

    metrics = {"voltage": voltage}
    details = "Voltage: %f V, Status: %s" % (voltage, state_readable)
    return {
        "changed": False,
        "msg": details,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": details
        }
    }