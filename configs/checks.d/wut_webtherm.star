def main(ctx, params):
    BASE_OID = ".1.3.6.1.4.1.5040.1.2"
    SENSOR_TYPES = [1, 2, 3, 6, 7, 8, 9, 16, 18, 36, 37, 38, 42]
    
    def extract_oid_suffix(oid):
        if oid.startswith(BASE_OID):
            return oid[len(BASE_OID):].lstrip(".")
        return oid
    
    def parse_snmp_line(line):
        if not line or "=" not in line:
            return None, None
        parts = line.split("=", 1)
        if len(parts) != 2:
            return None, None
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        suffix = extract_oid_suffix(oid_part)
        parts_suffix = suffix.split(".")
        if len(parts_suffix) < 2:
            return None, None
        sensor_id = parts_suffix[-1]
        if value_part.startswith("INTEGER: "):
            val_str = value_part[9:]
            return sensor_id, int(val_str) if val_str.isdigit() else 0
        elif value_part.startswith("STRING: "):
            val = value_part[8:].strip().strip('"')
            return sensor_id, val
        else:
            return sensor_id, value_part
    
    if params.get("_discover"):
        sensors_by_id = {}
        for stype in SENSOR_TYPES:
            base = "%s.%s.1" % (BASE_OID, stype)
            res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                          "-On", params.get("host", "localhost"), base], mutates=False)
            lines = res.stdout.splitlines() if res.stdout else []
            for line in lines:
                sensor_id, val = parse_snmp_line(line)
                if sensor_id and sensor_id not in sensors_by_id:
                    sensors_by_id[sensor_id] = {"type": "temp"}
        discovered = []
        for sensor_id, data in sensors_by_id.items():
            discovered.append({
                "item": sensor_id,
                "params": {"levels": (30.0, 35.0)},
                "metrics": ["temperature"]
            })
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(discovered),
            "data": {"discovery": discovered}
        }
    
    item = params.get("item", "")
    sensors = {}
    for stype in SENSOR_TYPES:
        base = "%s.%s.1" % (BASE_OID, stype)
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                      "-On", params.get("host", "localhost"), base], mutates=False)
        lines = res.stdout.splitlines() if res.stdout else []
        for line in lines:
            sensor_id, val = parse_snmp_line(line)
            if sensor_id:
                if stype <= 9:
                    sensor_type = "temp"
                else:
                    if sensor_id in ("1", "2", "3"):
                        sensor_type = {"1": "temp", "2": "humid", "3": "air_pressure"}.get(sensor_id, "temp")
                    else:
                        sensor_type = "temp"
                reading_str = ""
                if type(val) == "string":
                    reading_str = val.replace(",", ".")
                elif type(val) == "int":
                    reading_str = str(val)
                else:
                    reading_str = str(val)
                if reading_str and "---" not in reading_str:
                    # Convert to float safely using string.isdigit() checks
                    # Handle negative numbers and decimals
                    clean = reading_str.strip()
                    has_dot = "." in clean
                    if has_dot:
                        parts = clean.split(".")
                        if len(parts) == 2 and parts[0].lstrip("-").isdigit() and parts[1].isdigit():
                            reading = float(clean)
                            sensors[sensor_id] = {"type": sensor_type, "reading": reading}
                    elif clean.lstrip("-").isdigit():
                        reading = float(clean)
                        sensors[sensor_id] = {"type": sensor_type, "reading": reading}
    
    if item not in sensors:
        return {
            "changed": False,
            "msg": "sensor %s not found" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    sensor = sensors[item]
    if sensor["type"] != "temp":
        return {
            "changed": False,
            "msg": "sensor %s is %s type, not temperature" % (item, sensor["type"]),
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    temp = sensor["reading"]
    warn, crit = params.get("levels", (30.0, 35.0))
    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    return {
        "changed": False,
        "msg": "Temperature: %f C" % temp,
        "data": {
            "state": state,
            "metrics": {"temperature": temp},
            "details": ""
        }
    }