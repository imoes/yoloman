SENSOR_TYPE_NAMES = {
    "0": "undefined", "1": "temperature", "2": "humidity", "3": "power",
    "4": "lowVoltage", "5": "current", "6": "aclmvVoltage", "7": "aclmpVoltage",
    "8": "aclmpPower", "9": "water", "10": "smoke", "11": "vibration",
    "12": "motion", "13": "glass", "14": "door", "15": "keypad",
    "16": "panicButton", "17": "keyStation", "18": "digInput", "22": "light",
    "24": "dewpoint", "26": "tacDio", "36": "acVoltage", "37": "acCurrent",
    "38": "dcVoltage", "39": "dcCurrent", "41": "rmsVoltage", "42": "rmsCurrent",
    "43": "activePower", "44": "reactivePower", "513": "tempHum",
    "32767": "custom", "32769": "temperatureCombo", "32770": "humidityCombo",
    "540": "tempHum",
}

BASE_OID = ".1.3.6.1.4.1.3699.1.1.11.1.21.1.1"


def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)


def _discover(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    sysDescr = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv",
                        host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if sysDescr.rc != 0:
        return {"changed": False, "msg": "no enivromux device found",
                "data": {"discovery": []}}

    if not _is_enviromux(sysDescr.stdout):
        return {"changed": False, "msg": "no enivromux device found",
                "data": {"discovery": []}}

    res = ctx.run(["snmpbulkwalk", "-v2c", "-c", community, "-Cr50",
                   "-OQ", "-Ov", host, BASE_OID], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "no enivromux sensors found",
                "data": {"discovery": []}}

    sensors = _parse_section(res.stdout)
    discovery = []
    for name, sensor in sensors.items():
        if sensor["type"] in ["humidity", "humidityCombo"]:
            discovery.append({"item": name, "params": {},
                              "metrics": ["humidity"]})
    return {"changed": False,
            "msg": "discovered %d humidity sensors" % len(discovery),
            "data": {"discovery": discovery}}


def _check(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")

    sysDescr = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv",
                        host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if sysDescr.rc != 0:
        return {"changed": False, "msg": "no enivromux device found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if not _is_enviromux(sysDescr.stdout):
        return {"changed": False, "msg": "no enivromux device found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run(["snmpbulkwalk", "-v2c", "-c", community, "-Cr50",
                   "-OQ", "-Ov", host, BASE_OID], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "no enivromux sensors found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sensors = _parse_section(res.stdout)
    if item not in sensors:
        return {"changed": False, "msg": "no such sensor: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sensor = sensors[item]
    if sensor["type"] not in ["humidity", "humidityCombo"]:
        return {"changed": False, "msg": "sensor is not a humidity sensor",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    value = sensor["value"]
    warn = params.get("warn")
    crit = params.get("crit")

    state = "OK"
    if warn != None and crit != None:
        critF = float(crit)
        warnF = float(warn)
        if value >= critF:
            state = "CRIT"
        elif value >= warnF:
            state = "WARN"

    return {"changed": False,
            "msg": "Humidity: %f %%" % value,
            "data": {"state": state, "metrics": {"humidity": value},
                     "details": "Sensor: %s, Value: %f %%" % (item, value)}}


def _is_enviromux(sysDescrOid):
    return sysDescrOid.startswith(".1.3.6.1.4.1.3699.1.1.11")


def _parse_section(output):
    sensors = {}
    lines = output.splitlines()
    for line in lines:
        fields = line.split()
        if len(fields) < 6:
            continue
        idx = fields[0]
        type_id = fields[1]
        description = fields[2]
        value_raw = fields[3]
        min_raw = fields[4]
        max_raw = fields[5]

        value = _parse_value(value_raw)
        if value == None:
            continue

        min_thr = _parse_value(min_raw)
        max_thr = _parse_value(max_raw)

        name = description + " " + idx
        sensors[name] = {
            "type": SENSOR_TYPE_NAMES.get(type_id, "unknown"),
            "value": value,
            "min_threshold": min_thr,
            "max_threshold": max_thr,
        }
    return sensors


def _parse_value(token):
    parts = token.split()
    if len(parts) == 0:
        return None
    v = parts[0]
    cleaned = v
    if cleaned.startswith('"') and cleaned.endswith('"'):
        cleaned = cleaned[1:-1]
    if _is_number(cleaned):
        return float(cleaned)
    return None


def _is_number(s):
    if s == None or len(s) == 0:
        return False
    neg = False
    body = s
    if body.startswith("-"):
        neg = True
        body = body[1:]
    if len(body) == 0:
        return False
    has_dot = False
    digit_seen = False
    for ch in body:
        if ch == ".":
            if has_dot:
                return False
            has_dot = True
        elif ch >= "0" and ch <= "9":
            digit_seen = True
        else:
            return False
    return digit_seen