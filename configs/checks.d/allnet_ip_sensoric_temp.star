# allnet_ip_sensoric_temp
# Translated from Checkmk check mk.plugins.allnet_ip_sensoric
# Temperature sensors read from Allnet IP sensor devices via SNMP.

# Allnet IP Sensoric MIB sensor table column OIDs.
# The base OID for the sensor table is .1.3.6.1.4.1.31447.2
# Each sensor has columns: name(1), function(2), unit(3), value_float(4)
BASE = ".1.3.6.1.4.1.31447.2"
COL_NAME = BASE + ".1"
COL_FUNCTION = BASE + ".2"
COL_UNIT = BASE + ".3"
COL_VALUE = BASE + ".4"

# Function codes (from Allnet IP Sensoric MIB).
FUNC_TEMP = "1"
UNIT_TEMP = "\u00b0C"

# Default temperature thresholds from Checkmk check_default_parameters.
DEFAULT_LEVELS = (35.0, 40.0)


def _snmp_get(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout:
        return ""
    val = res.stdout.strip()
    # -Oqv gives bare value; strip surrounding quotes if present.
    if val.startswith('"') and val.endswith('"'):
        val = val[1:-1]
    return val


def _snmp_walk(ctx, host, community, oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return []
    lines = res.stdout.splitlines()
    entries = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        sp = line.split(" ", 1)
        if len(sp) < 2:
            continue
        oid_full = sp[0]
        val = sp[1]
        if val.startswith('"') and val.endswith('"'):
            val = val[1:-1]
        entries.append((oid_full, val))
    return entries


def _is_present(ctx, host, community):
    """Probe whether the Allnet IP sensor device responds."""
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, COL_NAME],
        mutates=False,
    )
    return res.rc == 0


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Probe that this device is actually an Allnet IP sensor.
    if not _is_present(ctx, community=community, host=host):
        if params.get("_discover"):
            return {
                "changed": False,
                "msg": "no Allnet IP sensor device found at %s" % host,
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "no Allnet IP sensor device found at %s" % host,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    # Walk the sensor name column to discover all sensors and their indices.
    name_entries = _snmp_walk(ctx, host, community, COL_NAME)
    if not name_entries:
        if params.get("_discover"):
            return {
                "changed": False,
                "msg": "no sensors found on %s" % host,
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "no sensors found on %s" % host,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    # Build the sensor data mapping, mimicking the Checkmk agent section.
    sensors = {}
    for oid_full, name_val in name_entries:
        # The index is the OID suffix after the column base.
        col_len = len(COL_NAME)
        if len(oid_full) <= col_len + 1:
            continue
        index = oid_full[col_len + 1:]
        sensors[index] = {"name": name_val}

    # Walk function and unit columns.
    func_entries = _snmp_walk(ctx, host, community, COL_FUNCTION)
    col_func_len = len(COL_FUNCTION)
    for oid_full, func_val in func_entries:
        if len(oid_full) <= col_func_len + 1:
            continue
        index = oid_full[col_func_len + 1:]
        if index in sensors:
            sensors[index]["function"] = func_val

    unit_entries = _snmp_walk(ctx, host, community, COL_UNIT)
    col_unit_len = len(COL_UNIT)
    for oid_full, unit_val in unit_entries:
        if len(oid_full) <= col_unit_len + 1:
            continue
        index = oid_full[col_unit_len + 1:]
        if index in sensors:
            sensors[index]["unit"] = unit_val

    value_entries = _snmp_walk(ctx, host, community, COL_VALUE)
    col_val_len = len(COL_VALUE)
    for oid_full, val_str in value_entries:
        if len(oid_full) <= col_val_len + 1:
            continue
        index = oid_full[col_val_len + 1:]
        if index in sensors:
            sensors[index]["value_float"] = val_str

    # Filter temperature sensors: function == "1" or unit == "°C".
    temp_sensors = {}
    for index, data in sensors.items():
        func = data.get("function", "")
        unit = data.get("unit", "")
        if func == FUNC_TEMP or unit == UNIT_TEMP:
            temp_sensors[index] = data

    if not temp_sensors:
        if params.get("_discover"):
            return {
                "changed": False,
                "msg": "no temperature sensors found on %s" % host,
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "no temperature sensors found on %s" % host,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    # DISCOVERY MODE
    if params.get("_discover"):
        discovery = []
        for index, data in temp_sensors.items():
            sensor_id = "sensor" + index
            name = data.get("name", "")
            # Compose item name mirroring _compose_item.
            if name:
                item = name + " Sensor " + index
            else:
                item = "Sensor " + index

            levels_raw = params.get("levels", DEFAULT_LEVELS)
            warn = levels_raw[0] if type(levels_raw) == "list" and len(levels_raw) >= 2 else DEFAULT_LEVELS[0]
            crit = levels_raw[1] if type(levels_raw) == "list" and len(levels_raw) >= 2 else DEFAULT_LEVELS[1]

            discovery.append({
                "item": item,
                "params": {"levels": (warn, crit)},
                "metrics": ["temperature"],
            })
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(discovery),
            "data": {"discovery": discovery},
        }

    # CHECK MODE for a single item.
    item = params.get("item", "")
    # Reverse _compose_item: extract index from "Sensor <num>" or "<name> Sensor <num>".
    suffix = ""
    idx = item.find("Sensor ")
    if idx >= 0:
        suffix = item[idx + len("Sensor "):].strip()
    sensor_id = "sensor" + suffix

    if sensor_id not in temp_sensors:
        return {
            "changed": False,
            "msg": "sensor not found: %s" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    val_str = temp_sensors[sensor_id].get("value_float", "")
    if not val_str:
        return {
            "changed": False,
            "msg": "no value for sensor %s" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    # Parse the float value; guard against non-numeric.
    val_clean = val_str.strip().strip('"')
    # Remove any type prefix if present (shouldn't be with -Oqv but guard).
    colon = val_clean.find(": ")
    if colon >= 0:
        val_clean = val_clean[colon + 2:]

    is_float = True
    try_float = val_clean
    # Simple numeric check without try/except.
    has_dot = False
    has_minus = False
    has_digit = False
    for ch in try_float:
        if ch == ".":
            if has_dot:
                is_float = False
                break
            has_dot = True
            has_minus = False
        elif ch == "-":
            if has_minus or has_digit:
                is_float = False
                break
            has_minus = True
        elif ch >= "0" and ch <= "9":
            has_digit = True
        else:
            is_float = False
            break
    if not is_float or not has_digit:
        return {
            "changed": False,
            "msg": "invalid value for sensor %s: %s" % (item, val_str),
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    value = float(val_clean)

    levels_raw = params.get("levels", DEFAULT_LEVELS)
    warn = DEFAULT_LEVELS[0]
    crit = DEFAULT_LEVELS[1]
    if type(levels_raw) == "list" and len(levels_raw) >= 2:
        warn = levels_raw[0]
        crit = levels_raw[1]
    elif type(levels_raw) == "tuple" and len(levels_raw) >= 2:
        warn = levels_raw[0]
        crit = levels_raw[1]

    state = "OK"
    if value >= crit:
        state = "CRIT"
    elif value >= warn:
        state = "WARN"

    return {
        "changed": False,
        "msg": "Temperature: %f C" % value,
        "data": {
            "state": state,
            "metrics": {"temperature": value},
            "details": "",
        },
    }