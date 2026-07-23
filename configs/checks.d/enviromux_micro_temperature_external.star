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
    "levels": (15.0, 16.0),
    "levels_lower": (10.0, 9.0),
}

def _check_temperature(reading, params):
    warn = params.get("levels", ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels"])[1] if params.get("levels") != None else ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels"][1]
    crit = params.get("levels", ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels"])[0] if params.get("levels") != None else ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels"][0]
    warn_lower = params.get("levels_lower", ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels_lower"])[1] if params.get("levels_lower") != None else ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels_lower"][1]
    crit_lower = params.get("levels_lower", ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels_lower"])[0] if params.get("levels_lower") != None else ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels_lower"][0]

    state = "OK"
    if reading == None:
        return "UNKNOWN"
    if crit_lower != None and reading <= crit_lower:
        state = "CRIT"
    elif warn_lower != None and reading <= warn_lower:
        state = "WARN"
    elif crit != None and reading >= crit:
        state = "CRIT"
    elif warn != None and reading >= warn:
        state = "WARN"
    return state

def _check_humidity(reading, params):
    warn = params.get("levels", (60, 80))[1] if params.get("levels") != None else (60, 80)[1]
    crit = params.get("levels", (60, 80))[0] if params.get("levels") != None else (60, 80)[0]
    if reading == None:
        return "UNKNOWN"
    state = "OK"
    if crit != None and reading >= crit:
        state = "CRIT"
    elif warn != None and reading >= warn:
        state = "WARN"
    return state

def main(ctx, params):
    if params.get("_discover"):
        base_oid = ".1.3.6.1.4.1.3699.1.1.12.1.2.1.1"
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c",
            params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            base_oid
        ])
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed: " + res.stderr,
                    "data": {"discovery": []}}

        data = {}
        for line in res.stdout.splitlines():
            if "=" not in line:
                continue
            oid_part, value_part = line.split("=", 1)
            oid = oid_part.strip()
            value = value_part.strip()
            tokens = oid.split(".")
            if len(tokens) < 20:
                continue
            sensor_index = tokens[-2]
            if not sensor_index.isdigit():
                continue
            if sensor_index not in data:
                data[sensor_index] = {"index": "", "type": "", "desc": "", "value": None}
            suffix = tokens[-1]
            if suffix == "1":
                val = value.split(":")[-1].strip().strip('"')
                data[sensor_index]["index"] = val
            elif suffix == "2":
                val = value.split(":")[-1].strip().strip('"')
                data[sensor_index]["type"] = val
            elif suffix == "3":
                val = value.split(":")[-1].strip()
                if val.startswith('"') and val.endswith('"'):
                    val = val[1:-1]
                data[sensor_index]["desc"] = val
            elif suffix == "4":
                val_str = value.split(":")[-1].strip()
                val_num = float(val_str) / 10.0 if val_str.replace('.','').replace('-','').isdigit() else None
                data[sensor_index]["value"] = val_num

        out = []
        for idx, s in data.items():
            sensor_type = SENSOR_TYPE_NAMES.get(s.get("type", ""), "unknown")
            item = s.get("desc", "") + " " + idx if "#" not in s.get("desc", "") else s.get("desc", "")
            if sensor_type in ["temperature", "temperatureCombo"]:
                out.append({"item": item, "params": ENVIROMUX_CHECK_DEFAULT_PARAMETERS.copy(),
                            "metrics": ["temp"]})
            elif sensor_type in ["humidity", "humidityCombo"]:
                out.append({"item": item, "params": {"levels": (60, 80)},
                            "metrics": ["humidity"]})
        return {"changed": False, "msg": "discovered %d sensors" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c",
        community,
        "-On",
        host,
        ".1.3.6.1.4.1.3699.1.1.12.1.2.1.1"
    ])
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = {}
    for line in res.stdout.splitlines():
        if "=" not in line:
            continue
        oid_part, value_part = line.split("=", 1)
        oid = oid_part.strip()
        value = value_part.strip()
        tokens = oid.split(".")
        if len(tokens) < 20:
            continue
        sensor_index = tokens[-2]
        if not sensor_index.isdigit():
            continue
        if sensor_index not in data:
            data[sensor_index] = {"index": "", "type": "", "desc": "", "value": None}
        suffix = tokens[-1]
        if suffix == "1":
            val = value.split(":")[-1].strip().strip('"')
            data[sensor_index]["index"] = val
        elif suffix == "2":
            val = value.split(":")[-1].strip().strip('"')
            data[sensor_index]["type"] = val
        elif suffix == "3":
            val = value.split(":")[-1].strip()
            if val.startswith('"') and val.endswith('"'):
                val = val[1:-1]
            data[sensor_index]["desc"] = val
        elif suffix == "4":
            val_str = value.split(":")[-1].strip()
            val_num = float(val_str) / 10.0 if val_str.replace('.','').replace('-','').isdigit() else None
            data[sensor_index]["value"] = val_num

    sensor = None
    for idx, s in data.items():
        sensor_item = s.get("desc", "") + " " + idx if "#" not in s.get("desc", "") else s.get("desc", "")
        if sensor_item == item:
            sensor = s
            break

    if sensor == None:
        return {"changed": False, "msg": "sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sensor_type = SENSOR_TYPE_NAMES.get(sensor.get("type", ""), "unknown")
    value = sensor.get("value")
    if value == None:
        return {"changed": False, "msg": "sensor value unavailable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = "OK"
    details = ""
    metrics = {}
    if sensor_type in ["temperature", "temperatureCombo"]:
        state = _check_temperature(value, params)
        details = "Temperature: %f C" % value
        metrics = {"temp": value}
    elif sensor_type in ["humidity", "humidityCombo"]:
        state = _check_humidity(value, params)
        details = "Humidity: %f %%" % value
        metrics = {"humidity": value}
    else:
        state = "UNKNOWN"
        details = "Unsupported sensor type: " + sensor_type

    msg = details
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": details}}