def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.4.1.5040.1.2"
        type_indices = [1, 2, 3, 6, 7, 8, 9, 16, 18, 36, 37, 38, 42]
        sensors = []

        for idx in type_indices:
            full_base = base_oid + "." + str(idx) + ".1"
            res = ctx.run([
                "snmpwalk",
                "-v2c",
                "-c", community,
                "-On", host,
                full_base
            ], mutates=False)
            if res.rc != 0:
                continue

            lines = res.stdout.splitlines()
            sensor_map = {}
            for line in lines:
                if line.find("=") < 0:
                    continue
                parts = line.split("=", 1)
                if len(parts) != 2:
                    continue
                oid_part = parts[0].strip()
                value_part = parts[1].strip()
                oid_segments = oid_part.split(".")
                if len(oid_segments) < 4:
                    continue
                sensor_id_str = oid_segments[-1]
                value_type_str = oid_segments[-2]
                if not sensor_id_str.isdigit():
                    continue
                if not value_type_str.isdigit():
                    continue
                sensor_id = int(sensor_id_str)
                value_type_oid = int(value_type_str)

                value_str = value_part
                if value_part.find(":") >= 0:
                    value_str = value_part.split(":", 1)[1].strip()
                if not value_str:
                    continue

                value = 0
                if value_str.isdigit() or (value_str.startswith("-") and value_str[1:].isdigit()):
                    value = int(value_str)
                elif value_str.find(".") >= 0:
                    # Validate float-like string
                    dot_idx = value_str.find(".")
                    left = value_str[:dot_idx]
                    right = value_str[dot_idx+1:]
                    if (left == "" or (left.isdigit() or (left.startswith("-") and left[1:].isdigit()))):
                        if right.isdigit():
                            value = float(value_str)
                        else:
                            continue
                    else:
                        continue
                else:
                    continue

                if not (sensor_id in sensor_map):
                    sensor_map[sensor_id] = {}
                sensor_map[sensor_id][value_type_oid] = value

            for sensor_id, data in sensor_map.items():
                if idx in [36, 37, 38]:
                    sensors.append({"item": str(sensor_id), "params": {}, "metrics": ["pressure_hpa"]})
        return {
            "changed": False,
            "msg": "discovered %d pressure sensors" % len(sensors),
            "data": {"discovery": sensors}
        }

    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.5040.1.2"
    found = False
    pressure_value = 0.0

    for idx in [36, 37, 38]:
        full_base = base_oid + "." + str(idx) + ".1"
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On", host,
            full_base
        ], mutates=False)
        if res.rc != 0:
            continue

        lines = res.stdout.splitlines()
        sensor_map = {}
        for line in lines:
            if line.find("=") < 0:
                continue
            parts = line.split("=", 1)
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            oid_segments = oid_part.split(".")
            if len(oid_segments) < 4:
                continue
            sensor_id_str = oid_segments[-1]
            value_type_str = oid_segments[-2]
            if not sensor_id_str.isdigit():
                continue
            if not value_type_str.isdigit():
                continue
            sensor_id = int(sensor_id_str)
            value_type_oid = int(value_type_str)

            value_str = value_part
            if value_part.find(":") >= 0:
                value_str = value_part.split(":", 1)[1].strip()
            if not value_str:
                continue

            value = 0
            if value_str.isdigit() or (value_str.startswith("-") and value_str[1:].isdigit()):
                value = int(value_str)
            elif value_str.find(".") >= 0:
                dot_idx = value_str.find(".")
                left = value_str[:dot_idx]
                right = value_str[dot_idx+1:]
                if (left == "" or (left.isdigit() or (left.startswith("-") and left[1:].isdigit()))):
                    if right.isdigit():
                        value = float(value_str)
                    else:
                        continue
                else:
                    continue
            else:
                continue

            if not (sensor_id in sensor_map):
                sensor_map[sensor_id] = {}
            sensor_map[sensor_id][value_type_oid] = value

        if item in sensor_map:
            pressure_raw = sensor_map[item].get(3)
            if pressure_raw != None:
                found = True
                pressure_value = float(pressure_raw) / 10.0
                break

    if not found:
        return {
            "changed": False,
            "msg": "pressure sensor " + item + " not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    summary = "%f hPa" % pressure_value
    return {
        "changed": False,
        "msg": summary,
        "data": {"state": "OK", "metrics": {"pressure_hpa": pressure_value}, "details": ""}
    }