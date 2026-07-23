# Module: papouch_th2e_sensors_humidity
# Read-only Starlark check for humidity sensors on PAPOUCH TH2E devices

# SNMP OIDs base
_BASE_OID = ".1.3.6.1.4.1.18248.20.1.2.1.1"

# Map sensor type by OID end
_SENSOR_TYPE_MAP = {
    "1": "temp",
    "2": "humidity",
    "3": "dewpoint",
}

# Map unit type
_UNITS_MAP = {
    "0": "c",
    "1": "f",
    "2": "k",
    "3": "percent",
}

# Map raw state to (check_state, readable)
_STATE_MAP = {
    "0": {"state": 0, "name": "OK"},
    "1": {"state": 3, "name": "not available"},
    "2": {"state": 1, "name": "over-flow"},
    "3": {"state": 1, "name": "under-flow"},
    "4": {"state": 2, "name": "error"},
}

# Checkmk default parameters
_DEFAULT_LEVELS = (30.0, 35.0)
_DEFAULT_LEVELS_LOWER = (12.0, 8.0)

def _parse_snmp_output(stdout):
    result = {}
    for line in stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_full = parts[0].strip()
        value_part = parts[1].strip()
        if not oid_full.startswith(_BASE_OID + "."):
            continue
        oid_end = oid_full[len(_BASE_OID) + 1:]
        parts_oid = oid_end.split(".")
        if len(parts_oid) != 2:
            continue
        sensor_index = parts_oid[1]
        if value_part.startswith("INTEGER:"):
            value_str = value_part[8:].strip()
        else:
            value_str = value_part
        if value_str.isdigit():
            value = int(value_str)
            result.setdefault(sensor_index, []).append(value)
    return result

def _format_state(state_code):
    if str(state_code) in _STATE_MAP:
        return _STATE_MAP[str(state_code)]
    return {"state": 3, "name": "unknown"}

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            _BASE_OID
        ], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "snmpwalk failed",
                "data": {"discovery": []}
            }
        parsed = _parse_snmp_output(res.stdout)
        sensors = []
        for sensor_idx, values in parsed.items():
            if len(values) < 4:
                continue
            state = values[1]
            unit = values[3]
            sensor_type = _SENSOR_TYPE_MAP.get(str(values[0]), "")
            if sensor_type == "humidity" and unit == 3:
                item = "Sensor " + sensor_idx
                sensors.append({
                    "item": item,
                    "params": {
                        "levels": _DEFAULT_LEVELS,
                        "levels_lower": _DEFAULT_LEVELS_LOWER
                    },
                    "metrics": ["humidity"]
                })
        return {
            "changed": False,
            "msg": "discovered %d humidity sensors" % len(sensors),
            "data": {"discovery": sensors}
        }

    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "item must be specified",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    if not item.startswith("Sensor "):
        return {
            "changed": False,
            "msg": "invalid item format",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    sensor_idx = item[7:]
    
    sensor_base = _BASE_OID + ".1." + sensor_idx
    res = ctx.run([
        "snmpget",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        sensor_base + ".1",
        sensor_base + ".2",
        sensor_base + ".3",
        sensor_base + ".4"
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "snmpget failed for " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    values = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_full = parts[0].strip()
        value_part = parts[1].strip()
        if not oid_full.startswith(sensor_base + "."):
            continue
        field = oid_full[len(sensor_base) + 1:]
        if value_part.startswith("INTEGER:"):
            value_str = value_part[8:].strip()
        else:
            value_str = value_part
        if value_str.isdigit():
            values[field] = int(value_str)
    
    required_fields = ["1", "2", "3", "4"]
    if not (len(required_fields) == 4 and "1" in values and "2" in values and "3" in values and "4" in values):
        return {
            "changed": False,
            "msg": "missing sensor data for " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    state_code = values["2"]
    reading = float(values["3"]) / 10.0
    unit = values["4"]
    
    if unit != 3:
        return {
            "changed": False,
            "msg": "sensor " + item + " is not humidity type",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    state_info = _format_state(state_code)
    
    levels_upper = params.get("levels", _DEFAULT_LEVELS)
    levels_lower = params.get("levels_lower", _DEFAULT_LEVELS_LOWER)
    warn_upper = levels_upper[0]
    crit_upper = levels_upper[1]
    warn_lower = levels_lower[0]
    crit_lower = levels_lower[1]
    
    state_code_num = state_info["state"]
    if state_code_num != 0:
        state = "CRIT"
        if state_code_num == 2:
            state = "CRIT"
        elif state_code_num == 1:
            state = "WARN"
        else:
            state = "UNKNOWN"
        return {
            "changed": False,
            "msg": "Status: " + state_info["name"],
            "data": {
                "state": state,
                "metrics": {"humidity": reading},
                "details": ""
            }
        }
    
    if reading >= crit_upper:
        state = "CRIT"
    elif reading >= warn_upper:
        state = "WARN"
    elif reading <= crit_lower:
        state = "CRIT"
    elif reading <= warn_lower:
        state = "WARN"
    else:
        state = "OK"
    
    msg = "Status: %s, Humidity: %f%%" % (state_info["name"], reading)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"humidity": reading},
            "details": ""
        }
    }