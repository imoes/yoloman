def main(ctx, params):
    # Constants
    OID_BASE_ENVIROMUX = ".1.3.6.1.4.1.3699.1.1.11.1.5.1.1"
    OID_BASE_ENVIROMUX5 = ".1.3.6.1.4.1.3699.1.1.10.1.5.1.1"
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

    def is_number(s):
        # Starlark has no try/except; use simple validation
        # Accept digits, optional minus, optional decimal point
        s = s.strip()
        if s == "":
            return False
        has_dot = False
        for i, c in enumerate(s):
            if c == "-":
                if i != 0:
                    return False
                continue
            if c == ".":
                if has_dot:
                    return False
                has_dot = True
                continue
            if c < "0" or c > "9":
                return False
        return True

    def parse_snmp_table(base_oid, string_table):
        sensors = {}
        for line in string_table:
            if len(line) < 6:
                continue
            sensor_idx, sensor_type, description, value_str, min_str, max_str = line
            # Skip unparseable values
            if not is_number(value_str) or value_str.strip() == "Not configured":
                continue
            value = float(value_str)
            sensor_min = float(min_str) if min_str and min_str.strip() != "Not configured" and is_number(min_str) else None
            sensor_max = float(max_str) if max_str and max_str.strip() != "Not configured" and is_number(max_str) else None
            sensor_name = description + " " + sensor_idx
            sensor_type_name = SENSOR_TYPE_NAMES.get(sensor_type, "unknown")
            # Scaling: temperature/current/power have factor 10
            if sensor_type_name in ["temperature", "power", "current", "temperatureCombo"]:
                value = value / 10.0
                if sensor_min != None:
                    sensor_min = sensor_min / 10.0
                if sensor_max != None:
                    sensor_max = sensor_max / 10.0
            sensors[sensor_name] = {
                "type": sensor_type_name,
                "value": value,
                "min_threshold": sensor_min,
                "max_threshold": sensor_max,
            }
        return sensors

    def discover_humidity(sensors):
        items = []
        for name, sensor in sensors.items():
            if sensor["type"] in ["humidity", "humidityCombo"]:
                items.append({"item": name, "params": {}, "metrics": ["humidity"]})
        return items

    def check_humidity_value(humidity, params):
        warn_upper = params.get("levels", [15.0, 16.0])[0]
        crit_upper = params.get("levels", [15.0, 16.0])[1]
        warn_lower = params.get("levels_lower", [10.0, 9.0])[0]
        crit_lower = params.get("levels_lower", [10.0, 9.0])[1]
        state = "OK"
        if humidity >= crit_upper or humidity <= crit_lower:
            state = "CRIT"
        elif humidity >= warn_upper or humidity <= warn_lower:
            state = "WARN"
        return state

    if params.get("_discover"):
        communities = ["public"]
        hosts = ["localhost"]
        for community in communities:
            for host in hosts:
                res5 = ctx.run([
                    "snmpwalk", "-v2c", "-c", community, "-On", host,
                    OID_BASE_ENVIROMUX5
                ], mutates=False)
                if res5.rc == 0:
                    lines = res5.stdout.strip().split("\n")
                    values = []
                    for line in lines:
                        if " = " not in line:
                            continue
                        _, val_part = line.rsplit(" = ", 1)
                        val_part = val_part.strip()
                        if ":" in val_part:
                            _, val = val_part.split(":", 1)
                        else:
                            val = val_part
                        val = val.strip()
                        values.append(val)
                    string_table = []
                    for i in range(0, len(values), 6):
                        if i + 5 < len(values):
                            string_table.append(values[i:i+6])
                    sensors = parse_snmp_table(OID_BASE_ENVIROMUX5, string_table)
                    items = discover_humidity(sensors)
                    if items:
                        return {
                            "changed": False,
                            "msg": "discovered %d humidity sensors" % len(items),
                            "data": {"discovery": items},
                        }
                res = ctx.run([
                    "snmpwalk", "-v2c", "-c", community, "-On", host,
                    OID_BASE_ENVIROMUX
                ], mutates=False)
                if res.rc == 0:
                    lines = res.stdout.strip().split("\n")
                    values = []
                    for line in lines:
                        if " = " not in line:
                            continue
                        _, val_part = line.rsplit(" = ", 1)
                        val_part = val_part.strip()
                        if ":" in val_part:
                            _, val = val_part.split(":", 1)
                        else:
                            val = val_part
                        val = val.strip()
                        values.append(val)
                    string_table = []
                    for i in range(0, len(values), 6):
                        if i + 5 < len(values):
                            string_table.append(values[i:i+6])
                    sensors = parse_snmp_table(OID_BASE_ENVIROMUX, string_table)
                    items = discover_humidity(sensors)
                    if items:
                        return {
                            "changed": False,
                            "msg": "discovered %d humidity sensors" % len(items),
                            "data": {"discovery": items},
                        }
        return {"changed": False, "msg": "discovered 0 humidity sensors",
                "data": {"discovery": []}}

    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    communities = ["public"]
    hosts = ["localhost"]
    sensors = {}
    found = False
    for community in communities:
        for host in hosts:
            res5 = ctx.run([
                "snmpwalk", "-v2c", "-c", community, "-On", host,
                OID_BASE_ENVIROMUX5
            ], mutates=False)
            if res5.rc == 0:
                lines = res5.stdout.strip().split("\n")
                values = []
                for line in lines:
                    if " = " not in line:
                        continue
                    _, val_part = line.rsplit(" = ", 1)
                    val_part = val_part.strip()
                    if ":" in val_part:
                        _, val = val_part.split(":", 1)
                    else:
                        val = val_part
                    val = val.strip()
                    values.append(val)
                string_table = []
                for i in range(0, len(values), 6):
                    if i + 5 < len(values):
                        string_table.append(values[i:i+6])
                sensors = parse_snmp_table(OID_BASE_ENVIROMUX5, string_table)
                if item in sensors:
                    found = True
                    break
            res = ctx.run([
                "snmpwalk", "-v2c", "-c", community, "-On", host,
                OID_BASE_ENVIROMUX
            ], mutates=False)
            if res.rc == 0:
                lines = res.stdout.strip().split("\n")
                values = []
                for line in lines:
                    if " = " not in line:
                        continue
                    _, val_part = line.rsplit(" = ", 1)
                    val_part = val_part.strip()
                    if ":" in val_part:
                        _, val = val_part.split(":", 1)
                    else:
                        val = val_part
                    val = val.strip()
                    values.append(val)
                string_table = []
                for i in range(0, len(values), 6):
                    if i + 5 < len(values):
                        string_table.append(values[i:i+6])
                sensors = parse_snmp_table(OID_BASE_ENVIROMUX, string_table)
                if item in sensors:
                    found = True
                    break
        if found:
            break

    if item not in sensors:
        return {"changed": False, "msg": "sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sensor = sensors[item]
    if sensor["type"] not in ["humidity", "humidityCombo"]:
        return {"changed": False, "msg": "sensor " + item + " is not a humidity sensor (type: " + sensor["type"] + ")",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    humidity = sensor["value"]
    state = check_humidity_value(humidity, params)
    return {
        "changed": False,
        "msg": "Humidity: %f %%" % humidity,
        "data": {
            "state": state,
            "metrics": {"humidity": humidity},
            "details": "",
        },
    }