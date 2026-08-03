def to_int(s):
    s = s if type(s) == "string" else str(s)
    s = s.strip()
    if len(s) == 0 or (s[0] == "-" and len(s) == 1):
        return 0
    if s[0] == "-":
        rest = s[1:]
    else:
        rest = s
    if rest.isdigit():
        return int(s)
    return 0

def to_float(s):
    s = s if type(s) == "string" else str(s)
    s = s.strip()
    if len(s) == 0:
        return None
    neg = False
    if s[0] == "-":
        neg = True
        s = s[1:]
    elif s[0] == "+":
        s = s[1:]
    digit_part = s
    if "." in digit_part:
        dot_parts = digit_part.split(".")
        if len(dot_parts) == 2:
            int_part = dot_parts[0]
            frac_part = dot_parts[1]
            if int_part == "" and frac_part == "":
                return None
            if int_part == "" and frac_part.isdigit():
                return float(s) if not neg else -float(s)
            if int_part.isdigit() and frac_part == "":
                return float(s) if not neg else -float(s)
            if int_part.isdigit() and frac_part.isdigit():
                return float(s) if not neg else -float(s)
    else:
        if s.isdigit():
            return float(s) if not neg else -float(s)
    return None

def strip_quotes(s):
    s = s.strip()
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        return s[1:-1]
    if len(s) >= 2 and s[0] == "'" and s[-1] == "'":
        return s[1:-1]
    return s

def to_sensor_id(s):
    s = strip_quotes(s).strip()
    if len(s) == 0:
        return 0
    hex_str = s.encode("utf-8").hex()
    return to_int(hex_str)

def main(ctx, params):
    check_type = params.get("check", "smoke")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    sys_oid_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if sys_oid_res.rc != 0:
        if sys_oid_res.rc == 127:
            return {"changed": False, "msg": "snmpget not found on host",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": "snmpget binary not installed"}}
        return {"changed": False, "msg": "SNMP query failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": sys_oid_res.stderr}}

    sys_oid = sys_oid_res.stdout.strip()
    if not sys_oid.startswith("1.3.6.1.4.1.35491"):
        return {"changed": False, "msg": "not a security master device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "sysObjectId is " + sys_oid}}

    walk_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.35491.30.3"],
        mutates=False,
    )
    if walk_res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed for sensors",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": walk_res.stderr}}

    supported_sensors = {50: "temp", 60: "humidity", 72: "smoke"}
    sensor_type_map = {}
    for k in supported_sensors:
        sensor_type_map[supported_sensors[k]] = k
    target_id = sensor_type_map.get(check_type, 72)

    sensors = {}
    lines = walk_res.stdout.splitlines()
    for line in lines:
        parts = line.split(None, 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        value = parts[1].strip()

        oid_parts = oid.split(".")
        if len(oid_parts) < 14:
            continue
        if oid_parts[10] != "1":
            continue
        sensor_num_str = oid_parts[11]
        field_str = oid_parts[12]

        if not sensor_num_str.lstrip("-").isdigit():
            continue
        sensor_num = int(sensor_num_str)
        if not field_str.lstrip("-").isdigit():
            continue
        field = int(field_str)

        if sensor_num not in sensors:
            sensors[sensor_num] = {
                "id": None,
                "value": None,
                "name": None,
                "alarm": -1,
                "crit_low": 0.0,
                "warn_low": 0.0,
                "warn_high": 0.0,
                "crit_high": 0.0,
            }

        s = sensors[sensor_num]

        if field == 5:
            s["name"] = strip_quotes(value)
        elif field == 1:
            s["id"] = to_sensor_id(value)
        elif field == 2:
            fval = to_float(value)
            if fval != None:
                s["value"] = fval
        elif field == 6:
            ival = to_int(value)
            s["alarm"] = ival
        elif field == 7:
            ival = to_int(value)
            s["crit_low"] = ival / 1000.0
        elif field == 8:
            ival = to_int(value)
            s["warn_low"] = ival / 1000.0
        elif field == 9:
            ival = to_int(value)
            s["warn_high"] = ival / 1000.0
        elif field == 10:
            ival = to_int(value)
            s["crit_high"] = ival / 1000.0

    target_sensors = {}
    for sensor_num in sensors:
        s = sensors[sensor_num]
        if s["id"] == target_id:
            display_name = s["name"] if s["name"] != None and len(s["name"]) > 0 else ""
            service_name = "%d %s" % (sensor_num, display_name)
            target_sensors[service_name] = s

    if not target_sensors:
        return {"changed": False, "msg": "no %s sensors found" % check_type,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "no %s sensors discovered" % check_type}}

    item = params.get("item", "")
    sensor = target_sensors.get(item)
    if sensor == None:
        return {"changed": False, "msg": "Sensor %s not found in SNMP output" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "sensor not found"}}

    if check_type == "smoke":
        if sensor["alarm"] == 99:
            return {"changed": False, "msg": "Smoke Sensor is not ready or bus element removed",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        value = sensor["value"]
        if value == None:
            return {"changed": False, "msg": "No Value for Sensor",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        if value == 0:
            return {"changed": False, "msg": "No Smoke",
                    "data": {"state": "OK", "metrics": {"smoke": 0}, "details": ""}}
        elif value == 1:
            return {"changed": False, "msg": "Smoke detected",
                    "data": {"state": "CRIT", "metrics": {"smoke": 1}, "details": ""}}
        else:
            return {"changed": False, "msg": "No Value for Sensor",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    elif check_type == "humidity":
        value = sensor["value"]
        if value == None:
            return {"changed": False, "msg": "Sensor value not in SNMP output",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

        levels = params.get("levels", None)
        levels_lower = params.get("levels_lower", None)

        if sensor["alarm"] != None and sensor["alarm"] > -1:
            if levels == None:
                levels = (sensor["warn_high"], sensor["crit_high"])
            if levels_lower == None:
                levels_lower = (sensor["warn_low"], sensor["crit_low"])

        state = "OK"
        msg = "Humidity: %f%%" % value

        if levels != None:
            warn_high = levels[0]
            crit_high = levels[1]
            if value >= crit_high:
                state = "CRIT"
            elif value >= warn_high:
                state = "WARN"

        if levels_lower != None:
            warn_low = levels_lower[0]
            crit_low = levels_lower[1]
            if value <= crit_low:
                state = "CRIT"
            elif value <= warn_low:
                state = "WARN"

        return {"changed": False, "msg": msg,
                "data": {"state": state, "metrics": {"humidity": value}, "details": ""}}

    elif check_type == "temp":
        value = sensor["value"]
        if value == None:
            return {"changed": False, "msg": "Sensor value is not in SNMP-WALK",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

        levels = params.get("levels", None)
        levels_lower = params.get("levels_lower", None)

        if levels == None:
            levels = (sensor["warn_high"], sensor["crit_high"])
        if levels_lower == None:
            levels_lower = (sensor["warn_low"], sensor["crit_low"])

        state = "OK"
        msg = "Temperature: %f C" % value

        if levels != None:
            warn_high = levels[0]
            crit_high = levels[1]
            if value >= crit_high:
                state = "CRIT"
            elif value >= warn_high:
                state = "WARN"

        if levels_lower != None:
            warn_low = levels_lower[0]
            crit_low = levels_lower[1]
            if value <= crit_low:
                state = "CRIT"
            elif value <= warn_low:
                state = "WARN"

        return {"changed": False, "msg": msg,
                "data": {"state": state, "metrics": {"temperature": value}, "details": ""}}

    return {"changed": False, "msg": "unknown check type: %s" % check_type,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}