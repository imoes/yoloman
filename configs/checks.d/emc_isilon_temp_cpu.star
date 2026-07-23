# Module-level constant: default thresholds for CPU temperature checks
DEFAULT_CPU_THRESHOLDS = (75.0, 85.0)

def _isilon_temp_item_name(sensor_name):
    if "CPU Throttle" in sensor_name:
        idx = sensor_name.find("(")
        if idx != -1:
            close_idx = sensor_name.find(")", idx)
            if close_idx != -1:
                return sensor_name[idx + 1:close_idx]
    if len(sensor_name) >= 5:
        return sensor_name[5:]
    return sensor_name

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.4.1.12124.2.54.1.3"
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On", host,
            base_oid
        ], mutates=False)
        if res.rc != 0:
            fail("snmpwalk failed: " + res.stderr)

        # Parse output: "OID = STRING: sensor_name" format
        sensors = []
        for line in res.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            # Extract string value from "STRING: value"
            val_part = parts[1]
            if val_part.startswith('STRING: '):
                sensor_name = val_part[8:]
                item_name = _isilon_temp_item_name(sensor_name)
                if item_name.startswith("CPU"):
                    sensors.append({"item": item_name, "params": {"levels": DEFAULT_CPU_THRESHOLDS},
                                   "metrics": ["temp"]})

        return {
            "changed": False,
            "msg": "discovered %d CPU temperature sensors" % len(sensors),
            "data": {"discovery": sensors}
        }

    # Check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Get both sensor name (OID .1.3.6.1.4.1.12124.2.54.1.3) and temperature value (OID .1.3.6.1.4.1.12124.2.54.1.4)
    name_oid = ".1.3.6.1.4.1.12124.2.54.1.3"
    temp_oid = ".1.3.6.1.4.1.12124.2.54.1.4"

    # Fetch sensor names
    res_name = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On", host,
        name_oid
    ], mutates=False)
    if res_name.rc != 0:
        return {
            "changed": False,
            "msg": "failed to fetch sensor names: " + res_name.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Fetch temperature values
    res_temp = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On", temp_oid
    ], mutates=False)
    if res_temp.rc != 0:
        return {
            "changed": False,
            "msg": "failed to fetch temperatures: " + res_temp.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Map item_name -> temperature value
    sensor_map = {}
    lines_name = res_name.stdout.splitlines()
    lines_temp = res_temp.stdout.splitlines()

    if len(lines_name) != len(lines_temp):
        return {
            "changed": False,
            "msg": "sensor name/value count mismatch",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    for i in range(len(lines_name)):
        name_line = lines_name[i].strip()
        temp_line = lines_temp[i].strip()

        # Parse name line: OID = STRING: "sensor_name"
        name_val = name_line.split(" = ")
        if len(name_val) != 2 or not name_val[1].startswith('STRING: '):
            continue
        sensor_name = name_val[1][8:].strip('"')

        # Parse temp line: OID = INTEGER: value
        temp_val = temp_line.split(" = ")
        if len(temp_val) != 2 or not temp_val[1].startswith('INTEGER: '):
            continue
        
        # Guard against invalid number parsing
        temp_str = temp_val[1][9:].strip()
        temp_value = 0.0
        if temp_str.isdigit() or (temp_str.find(".") != -1 and temp_str.replace(".", "", 1).isdigit()):
            temp_value = float(temp_str)
        else:
            continue

        item_name = _isilon_temp_item_name(sensor_name)
        sensor_map[item_name] = temp_value

    # Look up item
    if item not in sensor_map:
        return {
            "changed": False,
            "msg": "no such CPU temperature sensor: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    temp_value = sensor_map[item]
    levels = params.get("levels", DEFAULT_CPU_THRESHOLDS)
    warn, crit = levels[0], levels[1]

    # Check_temperature logic: upper thresholds
    if temp_value >= crit:
        state = "CRIT"
    elif temp_value >= warn:
        state = "WARN"
    else:
        state = "OK"

    msg = "%s: %s C" % (item, str(temp_value))

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temp": temp_value},
            "details": ""
        }
    }
