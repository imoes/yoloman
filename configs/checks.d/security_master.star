# Top-level constants and helpers
_BASE_OID = ".1.3.6.1.4.1.35491.30"

_SENSORS_IDS = {
    20: ("digital", "Schloss"),
    22: ("digital", "Relaisadapter AC"),
    23: ("digital", "Digitalausgang"),
    24: ("digital", "Steckdosenleiste"),
    38: ("digital", "Transponderleser"),
    39: ("digital", "Tastatur"),
    50: ("analog", "Temperatursensor"),
    51: ("digital", "Digitaleingang"),
    60: ("analog", "Feuchtesensor"),
    61: ("digital", "Netzspannungs Messadapter"),
    62: ("digital", "Sauerstoffsensor"),
    63: ("analog", "Analogsensor"),
    64: ("digital", "Wechselstromzaehler"),
    70: ("digital", "Zugangssensor (Tuerkontakt)"),
    71: ("digital", "Erschuetterungssensor"),
    72: ("digital", "Rauchmelder"),
    80: ("digital", "LHX 20 RS232"),
}

_SUPPORTED_SENSORS = {
    50: "temp",
    60: "humidity",
    72: "smoke",
}

def _safe_int(s):
    if s == None:
        return 0
    s = str(s).strip()
    if s == "":
        return 0
    is_negative = False
    if s.startswith("-"):
        is_negative = True
        s = s[1:]
    if s == "":
        return 0
    for c in s:
        if c < "0" or c > "9":
            return 0
    result = int(s)
    return -result if is_negative else result

def _safe_float(s):
    if s == None:
        return 0.0
    s = str(s).strip()
    if s == "" or s == "-" or s == "." or s == "-.":
        return 0.0
    has_point = False
    has_digit = False
    for c in s:
        if c >= "0" and c <= "9":
            has_digit = True
        elif c == ".":
            if has_point:
                return 0.0
            has_point = True
        elif c != "-":
            return 0.0
    if not has_digit:
        return 0.0
    return float(s)


def main(ctx, params):
    if params.get("_discover") == True:
        return _discover(ctx, params)
    return _check(ctx, params)


def _discover(ctx, params):
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        _BASE_OID
    ], mutates=False)
    
    lines = res.stdout.splitlines()
    sensor_data = {}
    for line in lines:
        if line == None or line == "":
            continue
        eq_idx = line.find("=")
        if eq_idx <= 0:
            continue
        oid_part = line[:eq_idx].strip()
        value_part = line[eq_idx+1:].strip()
        
        if not oid_part.startswith(_BASE_OID):
            continue
        tail = oid_part[len(_BASE_OID):].strip()
        
        parts = tail.split(".")
        if len(parts) < 5:
            continue
        sensor_num_str = parts[1]
        field_idx = int(parts[2])
        
        if field_idx != 3:
            continue
        
        idx = int(parts[3])
        
        if sensor_data.get(sensor_num_str) == None:
            sensor_data[sensor_num_str] = {
                "id": None,
                "value": None,
                "name": None,
                "alarm": None,
                "crit_low": None,
                "warn_low": None,
                "warn_high": None,
                "crit_high": None,
            }
        
        field = int(parts[4])
        
        val = value_part
        if val.startswith("STRING:"):
            val = val[7:].strip('"')
        elif val.startswith("INTEGER:"):
            val = val[8:].strip()
        elif val.startswith("Gauge32:"):
            val = val[8:].strip()
        elif val.startswith("Counter32:"):
            val = val[10:].strip()
        elif val.startswith("OID:"):
            val = val[4:].strip()
        
        if field == 1:
            sensor_data[sensor_num_str]["id"] = _safe_int(val)
        elif field == 2:
            sensor_data[sensor_num_str]["value"] = _safe_float(val)
        elif field == 5:
            sensor_data[sensor_num_str]["name"] = val
        elif field == 6:
            sensor_data[sensor_num_str]["alarm"] = _safe_int(val)
        elif field == 7:
            sensor_data[sensor_num_str]["crit_low"] = _safe_float(val) / 1000.0
        elif field == 8:
            sensor_data[sensor_num_str]["warn_low"] = _safe_float(val) / 1000.0
        elif field == 9:
            sensor_data[sensor_num_str]["warn_high"] = _safe_float(val) / 1000.0
        elif field == 10:
            sensor_data[sensor_num_str]["crit_high"] = _safe_float(val) / 1000.0
    
    discovered = []
    for num_str, data in sensor_data.items():
        sensor_id = data["id"]
        if sensor_id == None or _SUPPORTED_SENSORS.get(sensor_id) == None:
            continue
        
        sensor_type = _SUPPORTED_SENSORS[sensor_id]
        if sensor_type == "smoke":
            item = num_str + " " + (data["name"] or "SmokeSensor")
            discovered.append({
                "item": item,
                "params": {},
                "metrics": ["smoke_detected"]
            })
        elif sensor_type == "humidity":
            item = num_str + " " + (data["name"] or "HumiditySensor")
            discovered.append({
                "item": item,
                "params": {},
                "metrics": ["humidity"]
            })
        elif sensor_type == "temp":
            item = num_str + " " + (data["name"] or "TempSensor")
            discovered.append({
                "item": item,
                "params": {},
                "metrics": ["temperature"]
            })
    
    return {
        "changed": False,
        "msg": "discovered %d sensors" % len(discovered),
        "data": {"discovery": discovered}
    }


def _check(ctx, params):
    item = params.get("item", "")
    
    parts = item.split(" ", 1)
    if len(parts) < 1:
        return {
            "changed": False,
            "msg": "invalid item format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    sensor_num_str = parts[0]
    sensor_type = None
    
    if len(parts) > 1:
        name = parts[1]
        if name.find("Smoke") != -1:
            sensor_type = "smoke"
        elif name.find("Humidity") != -1 or name.find("Feucht") != -1:
            sensor_type = "humidity"
        elif name.find("Temp") != -1:
            sensor_type = "temp"
    
    if sensor_type == None:
        sensor_type = "smoke"
    
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        _BASE_OID
    ], mutates=False)
    
    lines = res.stdout.splitlines()
    sensor_data = {}
    for line in lines:
        if line == None or line == "":
            continue
        eq_idx = line.find("=")
        if eq_idx <= 0:
            continue
        oid_part = line[:eq_idx].strip()
        value_part = line[eq_idx+1:].strip()
        
        if not oid_part.startswith(_BASE_OID):
            continue
        tail = oid_part[len(_BASE_OID):].strip()
        
        parts_oid = tail.split(".")
        if len(parts_oid) < 5:
            continue
        
        num = parts_oid[1]
        field = int(parts_oid[2])
        
        if field != 3:
            continue
        
        idx = int(parts_oid[3])
        
        val = value_part
        if val.startswith("STRING:"):
            val = val[7:].strip('"')
        elif val.startswith("INTEGER:"):
            val = val[8:].strip()
        elif val.startswith("Gauge32:"):
            val = val[8:].strip()
        elif val.startswith("Counter32:"):
            val = val[10:].strip()
        elif val.startswith("OID:"):
            val = val[4:].strip()
        
        field_idx = int(parts_oid[4])
        
        if sensor_data.get(num) == None:
            sensor_data[num] = {
                "id": None,
                "value": None,
                "name": None,
                "alarm": None,
                "crit_low": None,
                "warn_low": None,
                "warn_high": None,
                "crit_high": None,
            }
        
        if field_idx == 1:
            sensor_data[num]["id"] = _safe_int(val)
        elif field_idx == 2:
            sensor_data[num]["value"] = _safe_float(val)
        elif field_idx == 5:
            sensor_data[num]["name"] = val
        elif field_idx == 6:
            sensor_data[num]["alarm"] = _safe_int(val)
        elif field_idx == 7:
            sensor_data[num]["crit_low"] = _safe_float(val) / 1000.0
        elif field_idx == 8:
            sensor_data[num]["warn_low"] = _safe_float(val) / 1000.0
        elif field_idx == 9:
            sensor_data[num]["warn_high"] = _safe_float(val) / 1000.0
        elif field_idx == 10:
            sensor_data[num]["crit_high"] = _safe_float(val) / 1000.0
    
    sensor = None
    if sensor_data.get(sensor_num_str) != None:
        sensor = sensor_data[sensor_num_str]
    
    if sensor == None or sensor["id"] == None:
        return {
            "changed": False,
            "msg": "sensor not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    sensor_id = sensor["id"]
    if _SUPPORTED_SENSORS.get(sensor_id) == None:
        return {
            "changed": False,
            "msg": "unsupported sensor type",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    detected_type = _SUPPORTED_SENSORS[sensor_id]
    if sensor_type != detected_type and detected_type in ["smoke", "humidity", "temp"]:
        sensor_type = detected_type
    
    if sensor_type == "smoke":
        return _check_smoke(item, sensor)
    elif sensor_type == "humidity":
        return _check_humidity(item, sensor, params)
    elif sensor_type == "temp":
        return _check_temp(item, sensor, params)
    else:
        return {
            "changed": False,
            "msg": "unknown sensor type",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }


def _check_smoke(item, sensor):
    alarm = sensor["alarm"]
    value = sensor["value"]
    
    if alarm == 99:
        return {
            "changed": False,
            "msg": "Smoke Sensor is not ready or bus element removed",
            "data": {"state": "UNKNOWN", "metrics": {"smoke_detected": 0}, "details": ""}
        }
    
    if value == 0:
        return {
            "changed": False,
            "msg": "No Smoke",
            "data": {"state": "OK", "metrics": {"smoke_detected": 0}, "details": ""}
        }
    elif value == 1:
        return {
            "changed": False,
            "msg": "Smoke detected",
            "data": {"state": "CRIT", "metrics": {"smoke_detected": 1}, "details": ""}
        }
    else:
        return {
            "changed": False,
            "msg": "No Value for Sensor",
            "data": {"state": "UNKNOWN", "metrics": {"smoke_detected": 0}, "details": ""}
        }


def _check_humidity(item, sensor, params):
    value = sensor["value"]
    if value == None:
        return {
            "changed": False,
            "msg": "Sensor value is not in SNMP-WALK",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    levels = sensor.get("levels") or (70.0, 80.0)
    levels_lower = sensor.get("levels_low") or (20.0, 15.0)
    
    warn_high = None
    crit_high = None
    warn_low = None
    crit_low = None
    
    levels_param = params.get("levels")
    if type(levels_param) == "list" and len(levels_param) >= 2:
        warn_high = levels_param[0]
        crit_high = levels_param[1]
    elif type(levels_param) == "dict":
        warn_high = levels_param.get("upper")
        crit_high = levels_param.get("upper_critical")
    
    levels_lower_param = params.get("levels_lower")
    if type(levels_lower_param) == "list" and len(levels_lower_param) >= 2:
        warn_low = levels_lower_param[0]
        crit_low = levels_lower_param[1]
    elif type(levels_lower_param) == "dict":
        warn_low = levels_lower_param.get("lower")
        crit_low = levels_lower_param.get("lower_critical")
    
    if warn_high == None:
        warn_high = levels[0]
    if crit_high == None:
        crit_high = levels[1]
    if warn_low == None:
        warn_low = levels_lower[0]
    if crit_low == None:
        crit_low = levels_lower[1]
    
    state = "OK"
    if crit_high != None and value >= crit_high:
        state = "CRIT"
    elif warn_high != None and value >= warn_high:
        state = "WARN"
    elif crit_low != None and value <= crit_low:
        state = "CRIT"
    elif warn_low != None and value <= warn_low:
        state = "WARN"
    
    msg = "Humidity: %f%%" % value
    details = ""
    if warn_low != None or crit_low != None:
        details += " Lower limits: warning=%f%% critical=%f%%" % (warn_low, crit_low)
    if warn_high != None or crit_high != None:
        details += " Upper limits: warning=%f%% critical=%f%%" % (warn_high, crit_high)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": {"humidity": value}, "details": details.strip()}
    }


def _check_temp(item, sensor, params):
    value = sensor["value"]
    if value == None:
        return {
            "changed": False,
            "msg": "Sensor value is not in SNMP-WALK",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    levels = sensor.get("levels") or (30.0, 35.0)
    levels_lower = sensor.get("levels_low") or (10.0, 5.0)
    
    warn_high = None
    crit_high = None
    warn_low = None
    crit_low = None
    
    levels_param = params.get("levels")
    if type(levels_param) == "list" and len(levels_param) >= 2:
        warn_high = levels_param[0]
        crit_high = levels_param[1]
    elif type(levels_param) == "dict":
        warn_high = levels_param.get("upper")
        crit_high = levels_param.get("upper_critical")
    
    levels_lower_param = params.get("levels_lower")
    if type(levels_lower_param) == "list" and len(levels_lower_param) >= 2:
        warn_low = levels_lower_param[0]
        crit_low = levels_lower_param[1]
    elif type(levels_lower_param) == "dict":
        warn_low = levels_lower_param.get("lower")
        crit_low = levels_lower_param.get("lower_critical")
    
    if warn_high == None:
        warn_high = levels[0]
    if crit_high == None:
        crit_high = levels[1]
    if warn_low == None:
        warn_low = levels_lower[0]
    if crit_low == None:
        crit_low = levels_lower[1]
    
    state = "OK"
    if crit_high != None and value >= crit_high:
        state = "CRIT"
    elif warn_high != None and value >= warn_high:
        state = "WARN"
    elif crit_low != None and value <= crit_low:
        state = "CRIT"
    elif warn_low != None and value <= warn_low:
        state = "WARN"
    
    msg = "Temperature: %f C" % value
    details = ""
    if warn_low != None or crit_low != None:
        details += " Lower limits: warning=%f C critical=%f C" % (warn_low, crit_low)
    if warn_high != None or crit_high != None:
        details += " Upper limits: warning=%f C critical=%f C" % (warn_high, crit_high)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": {"temperature": value}, "details": details.strip()}
    }