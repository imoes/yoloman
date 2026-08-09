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

ENVIROMUX_CHECK_DEFAULT_PARAMETERS = {
    "levels": [15.0, 16.0],
    "levels_lower": [10.0, 9.0],
}

base_oid = ".1.3.6.1.4.1.3699.1.1.2.1.4.1.1"

def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        if not res.stdout:
            return {
                "changed": False,
                "msg": "no SNMP data",
                "data": {"discovery": []},
            }
        lines = res.stdout.splitlines()
        sensor_map = {}
        for line in lines:
            eq_idx = line.find("=")
            if eq_idx == -1:
                continue
            oid_part = line[:eq_idx].strip()
            value_part = line[eq_idx + 1:].strip()
            if not oid_part.startswith(base_oid + "."):
                continue
            suffix = oid_part[len(base_oid) + 1:]
            dot_idx = suffix.find(".")
            if dot_idx == -1:
                continue
            idx_str = suffix[:dot_idx]
            field_str = suffix[dot_idx + 1:]
            idx = int(idx_str) if idx_str.isdigit() else -1
            field = int(field_str) if field_str.isdigit() else -1
            if idx < 0 or field < 0:
                continue
            colon_idx = value_part.find(":")
            val = value_part[colon_idx + 1:].strip() if colon_idx != -1 else value_part.strip()
            if idx not in sensor_map:
                sensor_map[idx] = {}
            sensor_map[idx][field - 1] = val

        out = []
        for idx in sorted(sensor_map.keys()):
            data = sensor_map[idx]
            if 1 not in data or 2 not in data or 3 not in data:
                continue
            sensor_type_name = SENSOR_TYPE_NAMES.get(data[1], "unknown")
            description = data[2]
            item_name = description + " " + str(idx)
            if sensor_type_name == "power":
                out.append({
                    "item": item_name,
                    "params": {
                        "levels": [15.0, 16.0],
                        "levels_lower": [10.0, 9.0],
                    },
                    "metrics": ["voltage"],
                })

        return {
            "changed": False,
            "msg": "discovered %d voltage sensors" % len(out),
            "data": {"discovery": out},
        }

    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
    if not res.stdout:
        return {
            "changed": False,
            "msg": "no SNMP data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    lines = res.stdout.splitlines()
    sensor_map = {}
    for line in lines:
        eq_idx = line.find("=")
        if eq_idx == -1:
            continue
        oid_part = line[:eq_idx].strip()
        value_part = line[eq_idx + 1:].strip()
        if not oid_part.startswith(base_oid + "."):
            continue
        suffix = oid_part[len(base_oid) + 1:]
        dot_idx = suffix.find(".")
        if dot_idx == -1:
            continue
        idx_str = suffix[:dot_idx]
        field_str = suffix[dot_idx + 1:]
        idx = int(idx_str) if idx_str.isdigit() else -1
        field = int(field_str) if field_str.isdigit() else -1
        if idx < 0 or field < 0:
            continue
        colon_idx = value_part.find(":")
        val = value_part[colon_idx + 1:].strip() if colon_idx != -1 else value_part.strip()
        if idx not in sensor_map:
            sensor_map[idx] = {}
        sensor_map[idx][field - 1] = val

    sensor_found = None
    for idx in sorted(sensor_map.keys()):
        data = sensor_map[idx]
        if 1 not in data or 2 not in data:
            continue
        sensor_type_name = SENSOR_TYPE_NAMES.get(data[1], "unknown")
        description = data[2]
        if sensor_type_name == "power":
            item_name = description + " " + str(idx)
            if item_name == item:
                sensor_found = data
                break

    if sensor_found == None:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if 3 not in sensor_found:
        return {
            "changed": False,
            "msg": "value not found for sensor: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    raw_val_str = sensor_found[3]
    if not raw_val_str:
        return {
            "changed": False,
            "msg": "empty value for sensor: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    # Validate numeric string before conversion
    numeric_str = raw_val_str.replace(".", "").replace("-", "")
    value = float(raw_val_str) / 10.0 if numeric_str.isdigit() or (raw_val_str.find(".") != -1 and numeric_str.isdigit()) else 0.0

    levels = params.get("levels", [15.0, 16.0])
    levels_lower = params.get("levels_lower", [10.0, 9.0])
    upper_warn = levels[0]
    upper_crit = levels[1]
    lower_warn = levels_lower[0]
    lower_crit = levels_lower[1]

    state = "OK"
    msg_parts = []
    msg_parts.append("Voltage is %f V" % value)

    if value >= upper_crit:
        state = "CRIT"
        msg_parts.append("(crit at %f V, warn at %f V)" % (upper_crit, upper_warn))
    elif value >= upper_warn:
        state = "WARN"
        msg_parts.append("(warn at %f V)" % upper_warn)
    elif value <= lower_crit:
        state = "CRIT"
        msg_parts.append("(crit below %f V, below warn %f V)" % (lower_crit, lower_warn))
    elif value <= lower_warn:
        state = "WARN"
        msg_parts.append("(below warn %f V)" % lower_warn)

    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": state,
            "metrics": {"voltage": value},
            "details": "",
        },
    }
