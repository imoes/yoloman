def _parse_sensor_type(values):
    def values_until(x):
        first = True
        for v in values[:x]:
            if v == "":
                first = False
        second = True
        for v in values[x:]:
            if v != "":
                second = False
        return first and second

    if values_until(2):
        return "TEMP"
    if values_until(3):
        return "TEMP_ACTIVE_POWER"
    if values_until(4):
        return "TEMP_ANALOG"
    if values_until(5):
        return "TEMP_HUMIDITY"
    return None

def _parse_sensor(values):
    temp = None
    heat_index = None
    humidity = None
    voltage = None
    power = None

    type_ = _parse_sensor_type(values)
    if type_ == None:
        return None

    if type_ == "TEMP":
        temp = float(values[0]) / 100.0
    elif type_ == "TEMP_ACTIVE_POWER":
        temp = float(values[0]) / 100.0
        power = values[2] == "1"
    elif type_ == "TEMP_ANALOG":
        temp = float(values[0]) / 100.0
        voltage = int(values[2])
    elif type_ == "TEMP_HUMIDITY":
        temp = float(values[0]) / 100.0
        humidity = float(values[2]) / 100.0
        heat_index = float(values[4]) / 100.0

    return {"temperature": temp, "heat_index": heat_index, "humidity": humidity, "voltage": voltage, "power": power}

def _fetch_oid_val(ctx, params, oid):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return ""
    return res.stdout.strip()

def _fetch_oid_val_raw(ctx, params, oid):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqn", host, oid], mutates=False)
    if res.rc != 0:
        return None
    parts = res.stdout.strip().split()
    if len(parts) < 2:
        return None
    return parts[1]

def _fetch_internal(ctx, params):
    temp_raw = _fetch_oid_val_raw(ctx, params, ".1.3.6.1.4.1.20916.1.8.1.1.2")
    if temp_raw == None:
        return None
    temp = float(temp_raw) / 100.0
    hum_raw = _fetch_oid_val_raw(ctx, params, ".1.3.6.1.4.1.20916.1.8.1.1.4")
    if hum_raw == None:
        return None
    humidity = float(hum_raw) / 100.0
    hi_raw = _fetch_oid_val_raw(ctx, params, ".1.3.6.1.4.1.20916.1.8.1.1.5")
    if hi_raw == None:
        return None
    heat_index = float(hi_raw) / 100.0
    return {"temperature": temp, "humidity": humidity, "heat_index": heat_index}

def _fetch_digital_sensors(ctx, params):
    sensors = []
    for i in range(1, 9):
        values = []
        for j in [1, 2, 3, 4, 5]:
            oid = ".1.3.6.1.4.1.20916.1.8.1.2.%d.%d" % (i, j)
            val = _fetch_oid_val(ctx, params, oid)
            values.append(val)
        parsed = _parse_sensor(values)
        sensors.append(parsed)
    return sensors

def _build_ra32e_section(ctx, params):
    internal = _fetch_internal(ctx, params)
    digital = _fetch_digital_sensors(ctx, params)
    has_digital = False
    for s in digital:
        if s != None:
            has_digital = True
            break
    if internal == None and not has_digital:
        return None
    return {"internal": internal, "digital": digital}

def _name_to_index(name):
    if name.startswith("Sensor ") or name.startswith("Heat Index "):
        suffix = name.replace("Sensor ", "").replace("Heat Index ", "")
        if suffix.isdigit():
            return int(suffix) - 1
    return None

def _is_heat_index_name(name):
    return name.startswith("Heat Index")

def _index_to_sensor(index):
    return "Sensor " + str(index + 1)

def _index_to_heat_index(index):
    return "Heat Index " + str(index + 1)

def _check_temperature(params, reading):
    levels = params.get("levels", (30.0, 35.0))
    warn = levels[0]
    crit = levels[1]
    state = "OK"
    if reading >= crit:
        state = "CRIT"
    elif reading >= warn:
        state = "WARN"
    return state

def main(ctx, params):
    if params.get("_discover"):
        probe = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if probe.rc == 127 or probe.rc != 0:
            return {"changed": False, "msg": "no RA32E device found", "data": {"discovery": [], "host_labels": {}}}
        check = probe.stdout.strip()
        if not check.startswith("1.3.6.1.4.1.20916.1.8"):
            return {"changed": False, "msg": "no RA32E device found", "data": {"discovery": [], "host_labels": {}}}

        section = _build_ra32e_section(ctx, params)
        if section == None:
            return {"changed": False, "msg": "no RA32E sensors data", "data": {"discovery": [], "host_labels": {}}}

        discovery = []
        internal = section.get("internal")
        digital = section.get("digital")

        if internal != None:
            discovery.append({"item": "Internal", "params": {"levels": (30.0, 35.0)}, "metrics": ["temperature"]})
            discovery.append({"item": "Heat Index", "params": {"levels": (30.0, 35.0)}, "metrics": ["heat_index"]})

        for i in range(len(digital)):
            sensor = digital[i]
            if sensor == None:
                continue
            if sensor.get("heat_index") != None:
                entry = {"item": _index_to_heat_index(i), "params": {"levels": (30.0, 35.0)}, "metrics": ["heat_index"]}
                discovery.append(entry)
            if sensor.get("temperature") != None:
                entry = {"item": _index_to_sensor(i), "params": {"levels": (30.0, 35.0)}, "metrics": ["temperature"]}
                discovery.append(entry)
            if sensor.get("humidity") != None:
                entry = {"item": _index_to_sensor(i), "params": {"levels": (70.0, 80.0)}, "metrics": ["humidity"]}
                discovery.append(entry)
            if sensor.get("voltage") != None:
                entry = {"item": _index_to_sensor(i), "params": {"voltage": (210, 180)}, "metrics": ["voltage"]}
                discovery.append(entry)
            if sensor.get("power") != None:
                entry = {"item": _index_to_sensor(i), "params": {}, "metrics": ["power"]}
                discovery.append(entry)

        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery, "host_labels": {}}}

    section = _build_ra32e_section(ctx, params)
    if section == None:
        return {"changed": False, "msg": "no RA32E device found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    item = params.get("item", "")
    internal = section.get("internal")
    digital = section.get("digital")
    rule = params.get("_rule", "temperature")

    if rule == "temperature":
        if internal != None and (item == "Internal" or item == "Heat Index"):
            if _is_heat_index_name(item):
                reading = internal.get("heat_index")
            else:
                reading = internal.get("temperature")
            if reading == None:
                return {"changed": False, "msg": "no temperature reading", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
            state = _check_temperature(params, reading)
            return {"changed": False, "msg": "%s: %f C" % (item, reading), "data": {"state": state, "metrics": {"temperature": reading}, "details": ""}}

        index = _name_to_index(item)
        if index == None or index >= len(digital):
            return {"changed": False, "msg": "no such sensor: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

        sensor = digital[index]
        if sensor == None:
            return {"changed": False, "msg": "sensor not present: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

        if _is_heat_index_name(item):
            reading = sensor.get("heat_index")
            if reading == None:
                return {"changed": False, "msg": "no heat index reading", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
            state = _check_temperature(params, reading)
            return {"changed": False, "msg": "%s: %f C" % (item, reading), "data": {"state": state, "metrics": {"heat_index": reading}, "details": ""}}

        reading = sensor.get("temperature")
        if reading == None:
            return {"changed": False, "msg": "no temperature reading", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        state = _check_temperature(params, reading)
        return {"changed": False, "msg": "%s: %f C" % (item, reading), "data": {"state": state, "metrics": {"temperature": reading}, "details": ""}}

    if rule == "humidity":
        levels = params.get("levels", (70.0, 80.0))
        warn = levels[0]
        crit = levels[1]
        if internal != None and item == "Internal":
            reading = internal.get("humidity")
            if reading == None:
                return {"changed": False, "msg": "no humidity reading", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
            state = "OK"
            if reading >= crit:
                state = "CRIT"
            elif reading >= warn:
                state = "WARN"
            return {"changed": False, "msg": "Humidity %s: %f%%" % (item, reading), "data": {"state": state, "metrics": {"humidity": reading}, "details": ""}}

        index = _name_to_index(item)
        if index == None or index >= len(digital):
            return {"changed": False, "msg": "no such sensor: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        sensor = digital[index]
        if sensor == None or sensor.get("humidity") == None:
            return {"changed": False, "msg": "no humidity reading", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        reading = sensor.get("humidity")
        state = "OK"
        if reading >= crit:
            state = "CRIT"
        elif reading >= warn:
            state = "WARN"
        return {"changed": False, "msg": "Humidity %s: %f%%" % (item, reading), "data": {"state": state, "metrics": {"humidity": reading}, "details": ""}}

    if rule == "voltage":
        levels = params.get("voltage", (210, 180))
        warn = levels[0]
        crit = levels[1]
        index = _name_to_index(item)
        if index == None or index >= len(digital):
            return {"changed": False, "msg": "no such sensor: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        sensor = digital[index]
        if sensor == None or sensor.get("voltage") == None:
            return {"changed": False, "msg": "no voltage reading", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        reading = sensor.get("voltage")
        state = "OK"
        if reading >= crit:
            state = "CRIT"
        elif reading >= warn:
            state = "WARN"
        return {"changed": False, "msg": "Voltage %s: %d V" % (item, reading), "data": {"state": state, "metrics": {"voltage": reading}, "details": ""}}

    if rule == "power":
        index = _name_to_index(item)
        if index == None or index >= len(digital):
            return {"changed": False, "msg": "no such sensor: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        sensor = digital[index]
        if sensor == None or sensor.get("power") == None:
            return {"changed": False, "msg": "no power reading", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        if sensor.get("power"):
            return {"changed": False, "msg": "Power %s: power detected" % item, "data": {"state": "OK", "metrics": {"power": 1}, "details": ""}}
        else:
            return {"changed": False, "msg": "Power %s: no power detected" % item, "data": {"state": "CRIT", "metrics": {"power": 0}, "details": ""}}

    return {"changed": False, "msg": "unknown rule: " + str(rule), "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}