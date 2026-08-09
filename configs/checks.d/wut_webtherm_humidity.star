def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    sys_oid = ".1.3.6.1.2.1.1.2.0"
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, sys_oid],
        mutates=False,
    )
    if res.rc != 0:
        if res.rc == 127:
            return {"changed": False, "msg": "snmpget not installed",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        return {"changed": False, "msg": "no response from " + host + " (" + res.stderr.strip() + ")",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sys_val = res.stdout.strip()
    if not sys_val.startswith(".1.3.6.1.4.1.5040.1.2."):
        return {"changed": False, "msg": "not a W&T WebTherm device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        parsed = _parse_section(ctx, community, host)
        discovery = []
        for sensor_id, values in parsed.items():
            if values["type"] == "humid":
                discovery.append({
                    "item": sensor_id,
                    "params": {"levels": [60.0, 65.0], "levels_lower": [40.0, 35.0]},
                    "metrics": ["humidity"],
                })
        return {"changed": False,
                "msg": "discovered %d humidity sensors" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    parsed = _parse_section(ctx, community, host)
    if item not in parsed or parsed[item]["type"] != "humid":
        return {"changed": False,
                "msg": "humidity sensor " + item + " not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    reading = parsed[item]["reading"]
    levels = params.get("levels", [60.0, 65.0])
    levels_lower = params.get("levels_lower", [40.0, 35.0])
    warn_high = levels[0] if len(levels) >= 2 else 60.0
    crit_high = levels[1] if len(levels) >= 2 else 65.0
    warn_low = levels_lower[0] if len(levels_lower) >= 2 else 40.0
    crit_low = levels_lower[1] if len(levels_lower) >= 2 else 35.0

    if reading >= crit_high or reading <= crit_low:
        state = "CRIT"
    elif reading >= warn_high or reading <= warn_low:
        state = "WARN"
    else:
        state = "OK"

    return {"changed": False,
            "msg": "%s: %f %% humidity" % (item, reading),
            "data": {
                "state": state,
                "metrics": {"humidity": reading},
                "details": "Sensor %s reports %f %% humidity" % (item, reading),
            }}


def _split_oid_value(line):
    line = line.strip()
    if not line:
        return ("", "")
    idx = line.find(" ")
    if idx == -1:
        return (line, "")
    return (line[:idx], line[idx + 1:])


def _parse_section(ctx, community, host):
    map_sensor_type = {"1": "temp", "2": "humid", "3": "air_pressure"}
    parsed = {}
    type_indices = [1, 2, 3, 6, 7, 8, 9, 16, 18, 36, 37, 38, 42]
    columns = ["2.1.1", "3.1.1", "8.1.1"]

    for idx in type_indices:
        for col in columns:
            res = ctx.run(
                ["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
                 ".1.3.6.1.4.1.5040.1.2." + str(idx) + ".1." + col],
                mutates=False,
            )
            for line in res.stdout.splitlines():
                oid, value = _split_oid_value(line)
                if not oid:
                    continue
                base = ".1.3.6.1.4.1.5040.1.2." + str(idx) + ".1." + col
                suffix = oid[len(base):]
                if not suffix or not suffix.startswith("."):
                    continue
                index = suffix[1:]
                index_parts = index.split(".")
                if len(index_parts) < 2:
                    continue
                sensor_id = index_parts[1]

                val = value.replace("\"", "").replace(",", ".")
                if not val or val == "---" or val == "":
                    continue
                if not _is_float(val):
                    continue
                reading = float(val)

                if idx <= 9:
                    stype = "temp"
                else:
                    stype = map_sensor_type.get(sensor_id, "unknown")

                if sensor_id not in parsed:
                    parsed[sensor_id] = {"type": stype, "reading": reading}
                else:
                    parsed[sensor_id]["reading"] = reading

    return parsed


def _is_float(s):
    s = s.strip()
    if not s:
        return False
    if s.startswith("-"):
        s = s[1:]
    if not s or not s.replace(".", "", 1).isdigit():
        return False
    return True