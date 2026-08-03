def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")

        # Probe for RA32E device via sysObjectID
        sysid_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Ovqn", host, ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sysid_res.rc != 0:
            return {"changed": False, "msg": "not an RA32E device", "data": {"discovery": []}}
        sysid = sysid_res.stdout.strip()
        if "1.3.6.1.4.1.20916.1.8" not in sysid:
            return {"changed": False, "msg": "not an RA32E device", "data": {"discovery": []}}

        discovery = []

        # Internal humidity
        internal_hum_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host,
             ".1.3.6.1.4.1.20916.1.8.1.1.2.1"],
            mutates=False,
        )
        if internal_hum_res.rc == 0:
            try_val = internal_hum_res.stdout.strip()
            if try_val != "":
                discovery.append({
                    "item": "Internal",
                    "params": {"levels": params.get("levels", (70.0, 80.0))},
                    "metrics": ["humidity"],
                })

        # Digital sensors: walk the base to find all sensors, then check type
        digital_walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Ovqn", host,
             ".1.3.6.1.4.1.20916.1.8.1.2"],
            mutates=False,
        )
        # Group values by sensor index
        sensors = {}
        if digital_walk.rc == 0:
            for line in digital_walk.stdout.splitlines():
                parts = line.split(None, 1)
                if len(parts) < 2:
                    continue
                oid = parts[0]
                val = parts[1].strip()
                # OID format: .1.3.6.1.4.1.20916.1.8.1.2.<index>.<col>
                suffix = oid[len(".1.3.6.1.4.1.20916.1.8.1.2"):]
                sub_parts = suffix.split(".")
                if len(sub_parts) >= 3:
                    index = sub_parts[1]
                    col = sub_parts[2]
                    if index not in sensors:
                        sensors[index] = {}
                    sensors[index][col] = val

        # For each digital sensor, check if all 5 columns are present (TEMP_HUMIDITY)
        for index in sorted(sensors.keys(), key=lambda x: int(x)):
            cols = sensors[index]
            # TEMP_HUMIDITY: all 5 values non-empty
            has_all = True
            for c in ["1", "2", "3", "4", "5"]:
                if c not in cols or cols[c] == "":
                    has_all = False
                    break
            if has_all:
                sensor_name = "Sensor " + str(int(index) + 1) if int(index) >= 0 else ""
                # index is 1-based in SNMP
                sensor_name = "Sensor " + str(int(index))
                discovery.append({
                    "item": sensor_name,
                    "params": {"levels": params.get("levels", (70.0, 80.0))},
                    "metrics": ["humidity"],
                })

        return {
            "changed": False,
            "msg": "discovered %d humidity sensors" % len(discovery),
            "data": {"discovery": discovery},
        }

    # Check mode
    item = params.get("item", "")
    warn, crit = params.get("levels", (70.0, 80.0))
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    humidity_val = None

    if item == "Internal":
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host,
             ".1.3.6.1.4.1.20916.1.8.1.1.2.1"],
            mutates=False,
        )
        if res.rc == 0:
            raw = res.stdout.strip()
            if raw != "":
                humidity_val = float(raw) / 100.0
    else:
        # Digital sensor: item is "Sensor N", N is 1-based
        sensor_num = None
        if item.startswith("Sensor "):
            num_str = item.replace("Sensor ", "")
            if num_str.isdigit():
                sensor_num = int(num_str)
        if sensor_num != None:
            # Walk sensor's columns
            base_oid = ".1.3.6.1.4.1.20916.1.8.1.2.%d" % sensor_num
            # Check if it's TEMP_HUMIDITY by getting all 5 columns
            cols = {}
            all_present = True
            for col in ["1", "2", "3", "4", "5"]:
                oid = base_oid + "." + col
                res = ctx.run(
                    ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
                    mutates=False,
                )
                if res.rc == 0:
                    raw = res.stdout.strip()
                    if raw != "":
                        cols[col] = raw
                    else:
                        cols[col] = ""
                        all_present = False
                else:
                    cols[col] = ""
                    all_present = False
            if all_present:
                # TEMP_HUMIDITY: humidity is col 3, value / 100
                humidity_val = float(cols["3"]) / 100.0

    if humidity_val == None:
        return {
            "changed": False,
            "msg": "humidity data not available for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state = "OK"
    if humidity_val >= crit:
        state = "CRIT"
    elif humidity_val >= warn:
        state = "WARN"

    return {
        "changed": False,
        "msg": "Humidity: %f%%" % humidity_val,
        "data": {
            "state": state,
            "metrics": {"humidity": humidity_val},
            "details": "",
        },
    }