# ra3s_sensors_voltage — Checkmk check translated to read-only Starlark
#
# Monitors the voltage of a RoomAlert RA3S digital analog sensor over SNMP.
# Discovery yields one service ("Sensor") when a TEMP_ANALOG digital sensor
# is present; check mode grades the voltage reading against ups_outphase
# levels (warn=4, crit=6 by default, upper-level grading).

VOLTAGE_OID = "1.3.6.1.4.1.20916.1.13.1.2.1"
SYS_OID = "1.3.6.1.2.1.1.2.0"
DESCRIBETION_OID = "1.3.6.1.2.1.1.1.0"
RA3S_SYS_PREFIX = "1.3.6.1.4.1.20916"
RA3S_DESCRIBED = "3S"

def _is_digit(value):
    if value == None:
        return False
    return value.isdigit()

def _detect_sensor_type(raw_data):
    count = 0
    for value in raw_data:
        if _is_digit(value):
            count += 1
    if count == 2:
        return "temp"
    if count == 3:
        return "temp/active_power"
    if count == 4:
        return "temp/analog"
    if count == 5:
        return "temp/extreme"
    if count == 6:
        return "temp/humidity"
    return None

def _walk_to_index(line):
    space = line.find(" ")
    if space == -1:
        return None, None
    oid = line[:space]
    value = line[space + 1:]
    return oid, value

def _gather_full_row(ctx, host, community, index_part):
    row = []
    for col in ["1", "2", "3", "4", "5", "6"]:
        col_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host,
             VOLTAGE_OID + "." + col + "." + index_part],
            mutates=False,
        )
        if col_res.rc == 0 and col_res.stdout.strip():
            row.append(col_res.stdout.strip())
        else:
            row.append("")
    return row

def _grade_voltage(voltage, warn, crit):
    if voltage == None:
        return "UNKNOWN", {}, "voltage reading not available"
    if voltage >= crit:
        state = "CRIT"
    elif voltage >= warn:
        state = "WARN"
    else:
        state = "OK"
    metrics = {"voltage": voltage}
    msg = "Voltage: %s V" % str(voltage)
    return state, metrics, msg

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")
    params_levels = params.get("levels", (4, 6))
    warn = params_levels[0]
    crit = params_levels[1]

    if params.get("_discover"):
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, VOLTAGE_OID],
            mutates=False,
        )
        if res.rc == 127:
            return {
                "changed": False,
                "msg": "device not reachable / snmp not available",
                "data": {"discovery": [], "host_labels": {}},
            }
        lines = res.stdout.splitlines()
        if len(lines) == 0:
            return {
                "changed": False,
                "msg": "no analog sensor found",
                "data": {"discovery": [], "host_labels": {}},
            }
        first_oid, _first_value = _walk_to_index(lines[0])
        if first_oid == None:
            return {
                "changed": False,
                "msg": "no analog sensor found",
                "data": {"discovery": [], "host_labels": {}},
            }
        index_part = first_oid[len(VOLTAGE_OID) + 1:]
        row = _gather_full_row(ctx, host, community, index_part)
        sensor_type = _detect_sensor_type(row)
        if sensor_type != "temp/analog":
            return {
                "changed": False,
                "msg": "no analog voltage sensor found",
                "data": {"discovery": [], "host_labels": {}},
            }
        discovery = [{
            "item": "Sensor",
            "params": {"levels": [4, 6]},
            "metrics": ["voltage"],
        }]
        host_labels = {"cmk/temp_analog_present": "yes"}
        return {
            "changed": False,
            "msg": "discovered %d item" % len(discovery),
            "data": {"discovery": discovery, "host_labels": host_labels},
        }

    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, VOLTAGE_OID],
        mutates=False,
    )
    if res.rc != 0 or res.rc == 127:
        return {
            "changed": False,
            "msg": "Voltage %s: could not read sensor data" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "snmp unreachable"},
        }
    lines = res.stdout.splitlines()
    if len(lines) == 0:
        return {
            "changed": False,
            "msg": "Voltage %s: no data" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "no voltage data"},
        }
    first_oid, _first_value = _walk_to_index(lines[0])
    if first_oid == None:
        return {
            "changed": False,
            "msg": "Voltage %s: no data" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "no voltage data"},
        }
    index_part = first_oid[len(VOLTAGE_OID) + 1:]
    row = _gather_full_row(ctx, host, community, index_part)
    sensor_type = _detect_sensor_type(row)
    if sensor_type != "temp/analog":
        return {
            "changed": False,
            "msg": "Voltage %s: not an analog sensor" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "no analog voltage sensor"},
        }
    voltage_str = row[2]
    if not _is_digit(voltage_str):
        return {
            "changed": False,
            "msg": "Voltage %s: invalid reading" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "invalid voltage value"},
        }
    voltage = int(voltage_str)
    state, metrics, msg = _grade_voltage(voltage, warn, crit)
    return {
        "changed": False,
        "msg": "Voltage %s: %s" % (item, msg),
        "data": {"state": state, "metrics": metrics, "details": msg},
    }