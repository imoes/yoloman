# ===== Starlark module: ra3s_sensors_humidity.star =====
# Translated Checkmk SNMP check: ra3s_sensors_humidity
# Monitors humidity on RoomAlert RA3S digital sensors (Temp/Humidity type)

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")

    # Probe for the real thing: the RA3S device via sysObjectID + sysDescr
    # DETECT_RA3S = all_of(contains(".1.3.6.1.2.1.1.2.0", "1.3.6.1.4.1.20916"),
    #                       contains(".1.3.6.1.2.1.1.1.0", "3S"))
    sys_obj = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if sys_obj.rc == 127:
        return {
            "changed": False,
            "msg": "snmpget not installed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    if sys_obj.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP probe failed: %s" % sys_obj.stderr.strip(),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    sys_obj_val = sys_obj.stdout.strip()
    if sys_obj_val.find("1.3.6.1.4.1.20916") == -1:
        return {
            "changed": False,
            "msg": "not a RoomAlert RA3S device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    sys_descr = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    if sys_descr.rc != 0 or sys_descr.stdout.find("3S") == -1:
        return {
            "changed": False,
            "msg": "not a RoomAlert RA3S device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Fetch the digital sensors table: .1.3.6.1.4.1.20916.1.13.1.2.1
    base_oid = ".1.3.6.1.4.1.20916.1.13.1.2.1"
    oids = ["1", "2", "3", "4", "5", "6"]

    if params.get("_discover"):
        # Discovery: walk each OID and determine sensor type
        # Sensor type is determined by counting how many of the 6 values are digit strings
        sensor_types = {}
        for oid in oids:
            full_oid = base_oid + "." + oid
            res = ctx.run(
                ["snmpwalk", "-v2c", "-c", community, "-Oqv", host, full_oid],
                mutates=False,
            )
            if res.rc != 0 or len(res.stdout.strip()) == 0:
                continue
            for line in res.stdout.strip().split("\n"):
                parts = line.split(" ", 1)
                if len(parts) < 2:
                    continue
                index = parts[0]
                value = parts[1]
                if sensor_types.get(index) == None:
                    sensor_types[index] = {}
                sensor_types[index][oid] = value

        discovery = []
        for sensor_index in sorted(sensor_types.keys()):
            raw_data = []
            for oid in oids:
                val = sensor_types[sensor_index].get(oid, "")
                raw_data.append(val)
            sensor_type = _detect_sensor_type(raw_data)
            if sensor_type == "temp/humidity":
                discovery.append({
                    "item": "Sensor",
                    "params": {"levels": (70.0, 80.0)},
                    "metrics": ["humidity"],
                })

        return {
            "changed": False,
            "msg": "discovered %d humidity sensors" % len(discovery),
            "data": {"discovery": discovery},
        }

    # Check mode: fetch all 6 OIDs for the Sensor item
    # Use snmpget with the full column OIDs to get all values
    values = {}
    for oid in oids:
        full_oid = base_oid + "." + oid
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, full_oid],
            mutates=False,
        )
        if res.rc != 0:
            continue
        values[oid] = res.stdout.strip()

    if len(values) == 0:
        return {
            "changed": False,
            "msg": "no digital sensor data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    raw_data = []
    for oid in oids:
        raw_data.append(values.get(oid, ""))

    sensor_type = _detect_sensor_type(raw_data)
    if sensor_type != "temp/humidity":
        return {
            "changed": False,
            "msg": "sensor is not a humidity sensor",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse humidity: OID 3, divided by 100
    humidity_raw = values.get("3", "")
    humidity = None
    if humidity_raw != "" and humidity_raw.isdigit():
        humidity = float(humidity_raw) / 100.0

    if humidity == None:
        return {
            "changed": False,
            "msg": "no humidity reading available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    levels = params.get("levels", (70.0, 80.0))
    warn = levels[0] if len(levels) >= 1 else 70.0
    crit = levels[1] if len(levels) >= 2 else 80.0

    if humidity >= crit:
        state = "CRIT"
    elif humidity >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "Humidity %f%%" % humidity,
        "data": {
            "state": state,
            "metrics": {"humidity": humidity},
            "details": "",
        },
    }


def _detect_sensor_type(raw_data):
    count = 0
    for value in raw_data:
        if value != "" and value.isdigit():
            count += 1
    lookup = {
        2: "temp",
        3: "temp/active_power",
        4: "temp/analog",
        5: "temp/extreme",
        6: "temp/humidity",
    }
    return lookup.get(count)