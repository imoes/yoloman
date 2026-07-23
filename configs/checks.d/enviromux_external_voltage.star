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

BASE_OID_ENVIROMUX = ".1.3.6.1.4.1.3699.1.1.11.1.5.1.1"
BASE_OID_ENVIROMUX5 = ".1.3.6.1.4.1.3699.1.1.10.1.5.1.1"

OID_INDEX = "1"
OID_TYPE = "2"
OID_DESCRIPTION = "3"
OID_VALUE = "7"
OID_MIN = "11"
OID_MAX = "12"

def parse_snmp_lines(lines):
    result = {}
    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        idx = stripped.find(" = ")
        if idx == -1:
            continue
        oid_part = stripped[:idx].strip()
        value_part = stripped[idx+3:].strip()
        if oid_part.endswith("." + OID_INDEX):
            sensor_idx = value_part.strip('"')
            result[sensor_idx] = {"index": sensor_idx}
        elif oid_part.endswith("." + OID_TYPE):
            sensor_idx = oid_part.rsplit(".", 1)[1]
            result.setdefault(sensor_idx, {})["type"] = value_part.strip('"')
        elif oid_part.endswith("." + OID_DESCRIPTION):
            sensor_idx = oid_part.rsplit(".", 1)[1]
            result.setdefault(sensor_idx, {})["description"] = value_part.strip('"')
        elif oid_part.endswith("." + OID_VALUE):
            sensor_idx = oid_part.rsplit(".", 1)[1]
            raw_val = value_part.strip('"')
            if raw_val.replace(".", "", 1).lstrip("-").isdigit():
                result.setdefault(sensor_idx, {})["value_raw"] = float(raw_val)
        elif oid_part.endswith("." + OID_MIN):
            sensor_idx = oid_part.rsplit(".", 1)[1]
            raw_val = value_part.strip('"')
            if raw_val.replace(".", "", 1).lstrip("-").isdigit():
                result.setdefault(sensor_idx, {})["min_raw"] = float(raw_val)
        elif oid_part.endswith("." + OID_MAX):
            sensor_idx = oid_part.rsplit(".", 1)[1]
            raw_val = value_part.strip('"')
            if raw_val.replace(".", "", 1).lstrip("-").isdigit():
                result.setdefault(sensor_idx, {})["max_raw"] = float(raw_val)
    return result

def main(ctx, params):
    base_oids = [BASE_OID_ENVIROMUX, BASE_OID_ENVIROMUX5]
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        out = []
        for base in base_oids:
            res = ctx.run([
                "snmpwalk", "-v2c", "-c", community, "-On", host,
                base + "." + OID_INDEX,
                base + "." + OID_TYPE,
                base + "." + OID_DESCRIPTION,
                base + "." + OID_VALUE,
                base + "." + OID_MIN,
                base + "." + OID_MAX
            ], mutates=False)
            if res.rc != 0:
                continue
            data = parse_snmp_lines(res.stdout.splitlines())
            for sensor_idx, sensor in data.items():
                sensor_type_name = SENSOR_TYPE_NAMES.get(sensor.get("type", ""), "unknown")
                if sensor_type_name == "power":
                    description = sensor.get("description", "")
                    item = description + " " + sensor.get("index", sensor_idx)
                    out.append({
                        "item": item,
                        "params": ENVIROMUX_CHECK_DEFAULT_PARAMETERS,
                        "metrics": ["voltage"]
                    })
        return {"changed": False, "msg": "discovered %d voltage sensors" % len(out),
                "data": {"discovery": out}}

    # Check mode
    item = params.get("item", "")
    found = False
    value = None
    warn_upper = params.get("levels", ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels"])[0]
    crit_upper = params.get("levels", ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels"])[1]
    warn_lower = params.get("levels_lower", ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels_lower"])[0]
    crit_lower = params.get("levels_lower", ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels_lower"])[1]

    for base in base_oids:
        if found:
            break
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            base + "." + OID_DESCRIPTION,
            base + "." + OID_VALUE
        ], mutates=False)
        if res.rc != 0:
            continue
        lines = res.stdout.splitlines()
        for line in lines:
            if not line.strip():
                continue
            idx = line.find(" = ")
            if idx == -1:
                continue
            oid_part = line[:idx].strip()
            value_part = line[idx+3:].strip()
            if oid_part.endswith("." + OID_VALUE):
                sensor_idx = oid_part.rsplit(".", 1)[1]
                desc_res = ctx.run([
                    "snmpwalk", "-v2c", "-c", community, "-On", host,
                    base + "." + OID_DESCRIPTION
                ], mutates=False)
                if desc_res.rc != 0:
                    continue
                for desc_line in desc_res.stdout.splitlines():
                    if not desc_line.strip():
                        continue
                    desc_idx = desc_line.find(" = ")
                    if desc_idx == -1:
                        continue
                    desc_oid = desc_line[:desc_idx].strip()
                    desc_val = desc_line[desc_idx+3:].strip()
                    if desc_oid.endswith("." + sensor_idx):
                        desc_item = desc_val.strip('"') + " " + sensor_idx
                        if desc_item == item:
                            raw_val = value_part.strip('"')
                            if raw_val.replace(".", "", 1).lstrip("-").isdigit():
                                value = float(raw_val) / 10.0
                            found = True
                            break
            if found:
                break

    if not found or value == None:
        return {"changed": False, "msg": "voltage sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = "OK"
    details = ""
    if value >= crit_upper or value <= crit_lower:
        state = "CRIT"
    elif value >= warn_upper or value <= warn_lower:
        state = "WARN"

    msg = "Input Voltage is %f V" % value

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"voltage": value}, "details": ""}}
