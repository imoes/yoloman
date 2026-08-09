SENSOR_TYPE_NAMES = {
    "0": "undefined",
    "1": "temperature",
    "2": "humidity",
    "3": "power",
    "4": "lowVoltage",
    "5": "current",
    "6": "aclmvVoltage",
    "7": "aclmpVoltage",
    "8": "aclmpPower",
    "9": "water",
    "10": "smoke",
    "11": "vibration",
    "12": "motion",
    "13": "glass",
    "14": "door",
    "15": "keypad",
    "16": "panicButton",
    "17": "keyStation",
    "18": "digInput",
    "22": "light",
    "24": "dewpoint",
    "26": "tacDio",
    "36": "acVoltage",
    "37": "acCurrent",
    "38": "dcVoltage",
    "39": "dcCurrent",
    "41": "rmsVoltage",
    "42": "rmsCurrent",
    "43": "activePower",
    "44": "reactivePower",
    "513": "tempHum",
    "32767": "custom",
    "32769": "temperatureCombo",
    "32770": "humidityCombo",
    "540": "tempHum",
}

SENSOR_STATUS_NAMES = {
    "0": "notconnected",
    "1": "normal",
    "2": "prealert",
    "3": "alert",
    "4": "acknowledged",
    "5": "dismissed",
    "6": "disconnected",
}

SENSOR_DIGITAL_VALUE_NAMES = {
    "0": "closed",
    "1": "open",
}

ENVIROMUX_CHECK_DEFAULT_PARAMETERS = {
    "levels": (15.0, 16.0),
    "levels_lower": (10.0, 9.0),
}


def _check_humidity(humidity, params):
    upper_warn = params.get("levels", ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels"])[0]
    upper_crit = params.get("levels", ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels"])[1]
    lower_warn = params.get("levels_lower", ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels_lower"])[0]
    lower_crit = params.get("levels_lower", ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels_lower"])[1]

    state = "OK"
    msg_parts = []
    msg_parts.append("Humidity: %f %%" % humidity)

    if humidity >= upper_crit:
        state = "CRIT"
        msg_parts.append("(crit at %f%%)" % upper_crit)
    elif humidity >= upper_warn:
        state = "WARN"
        msg_parts.append("(warn at %f%%)" % upper_warn)

    if humidity <= lower_crit:
        state = "CRIT"
        msg_parts.append("(crit below %f%%)" % lower_crit)
    elif humidity <= lower_warn:
        state = "WARN"
        msg_parts.append("(below lower warn at %f%%)" % lower_warn)

    return state, " ".join(msg_parts)


def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On",
            host,
            ".1.3.6.1.4.1.3699.1.1.12.1.2.1.1"
        ], mutates=False)
        if res.rc != 0:
            fail("snmpwalk failed: " + res.stderr)

        lines = res.stdout.splitlines()
        if len(lines) == 0:
            return {"changed": False, "msg": "no sensor data returned", "data": {"discovery": []}}

        entries = {}
        base_len = len(".1.3.6.1.4.1.3699.1.1.12.1.2.1.1.")
        for line in lines:
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_full = parts[0].strip()
            value = parts[1].strip()
            if not oid_full.startswith(".1.3.6.1.4.1.3699.1.1.12.1.2.1.1."):
                continue
            rel_oid = oid_full[base_len:]
            idx_part = rel_oid.split(".")[0]
            if not idx_part.isdigit():
                continue
            idx = int(idx_part)
            field_part = rel_oid.split(".")
            if len(field_part) < 2:
                continue
            field_idx_str = field_part[1]
            if not field_idx_str.isdigit():
                continue
            field_idx = int(field_idx_str)
            if idx not in entries:
                entries[idx] = {}
            if field_idx == 1:
                entries[idx]["index"] = value
            elif field_idx == 2:
                entries[idx]["type"] = value
            elif field_idx == 3:
                entries[idx]["description"] = value
            elif field_idx == 4:
                entries[idx]["value"] = value

        discovery = []
        for idx, e in entries.items():
            sensor_type = SENSOR_TYPE_NAMES.get(e.get("type", ""), "unknown")
            if sensor_type in ["humidity", "humidityCombo"]:
                name = e.get("description", "")
                if name == "":
                    name = "Humidity %s" % e.get("index", "")
                item = name
                discovery.append({
                    "item": item,
                    "params": {},
                    "metrics": ["humidity"]
                })

        return {
            "changed": False,
            "msg": "discovered %d humidity sensors" % len(discovery),
            "data": {"discovery": discovery}
        }

    item = params.get("item", "")
    if item == "":
        fail("item is required for check mode")

    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On",
        host,
        ".1.3.6.1.4.1.3699.1.1.12.1.2.1.1"
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "snmpwalk failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = res.stdout.splitlines()
    if len(lines) == 0:
        return {"changed": False, "msg": "no sensor data returned",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    entries = {}
    base_len = len(".1.3.6.1.4.1.3699.1.1.12.1.2.1.1.")
    for line in lines:
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_full = parts[0].strip()
        value = parts[1].strip()
        if not oid_full.startswith(".1.3.6.1.4.1.3699.1.1.12.1.2.1.1."):
            continue
        rel_oid = oid_full[base_len:]
        idx_part = rel_oid.split(".")[0]
        if not idx_part.isdigit():
            continue
        idx = int(idx_part)
        field_part = rel_oid.split(".")
        if len(field_part) < 2:
            continue
        field_idx_str = field_part[1]
        if not field_idx_str.isdigit():
            continue
        field_idx = int(field_idx_str)
        if idx not in entries:
            entries[idx] = {}
        if field_idx == 1:
            entries[idx]["index"] = value
        elif field_idx == 2:
            entries[idx]["type"] = value
        elif field_idx == 3:
            entries[idx]["description"] = value
        elif field_idx == 4:
            entries[idx]["value"] = value

    humidity_value = None
    for idx, e in entries.items():
        sensor_type = SENSOR_TYPE_NAMES.get(e.get("type", ""), "unknown")
        if sensor_type in ["humidity", "humidityCombo"]:
            name = e.get("description", "")
            if name == "":
                name = "Humidity %s" % e.get("index", "")
            if name == item:
                val_str = e.get("value", "")
                if val_str != "":
                    dot_pos = val_str.find(".")
                    if dot_pos >= 0:
                        before_dot = val_str[:dot_pos]
                        after_dot = val_str[dot_pos+1:]
                        if before_dot.isdigit() and after_dot.isdigit():
                            humidity_value = float(val_str) / 10.0
                    elif val_str.isdigit():
                        humidity_value = float(val_str) / 10.0
                break

    if humidity_value == None:
        return {"changed": False, "msg": "sensor item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state, msg = _check_humidity(humidity_value, params)
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"humidity": humidity_value},
            "details": ""
        }
    }