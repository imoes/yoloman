# Supermicro sensors check — SNMP based, read-only.

# OID bases for the three SNMP trees handled by the supermicro family.
HEALTH_BASE = ".1.3.6.1.4.1.10876.2"
SENSORS_BASE = ".1.3.6.1.4.1.10876.2.1.1.1.1"
SMART_BASE = ".1.3.6.1.4.1.10876.100.1.4.1"

# Sensor type codes used by the sensors section.
SENSOR_TYPE_FAN = "0"
SENSOR_TYPE_VOLTAGE = "1"
SENSOR_TYPE_TEMPERATURE = "2"
SENSOR_TYPE_STATUS = "3"

# Numeric health codes from the supermicro health OID (.2).
# 0 OK, 1 Warn, 2 Crit, 3 Unknown.
HEALTH_STATE_MAP = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}

# Ordering for picking the worst sensor/device status: lower index = worse.
# Index 0 (OK) is best, then 1 (WARN), then 3 (UNKNOWN), then 2 (CRIT).
WORST_ORDER = [0, 1, 3, 2]

# SMART status codes and labels.
SMART_STATUS_MAP = {"0": "OK", "1": "WARN", "2": "CRIT", "3": "UNKNOWN"}
SMART_LABEL_MAP = {"0": "Healthy", "1": "Warning", "2": "Critical", "3": "Unknown"}


def _is_int(s):
    if s == None or s == "":
        return False
    if s[0] == "-" or s[0] == "+":
        return s[1:].isdigit()
    return s.isdigit()


def _snmp_present(ctx, params):
    """Probe whether supermicro hardware is actually present via SNMP."""
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, HEALTH_BASE + ".3"],
        mutates=False,
    )
    # rc == 127 means the binary isn't installed; rc != 0 means no response.
    return res.rc == 0


def _snmp_get(ctx, params, oid):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0 or res.stdout == "":
        return None
    return res.stdout.strip()


def _snmp_walk(ctx, params, oid):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc != 0 or res.stdout == "":
        return []
    out = []
    for line in res.stdout.splitlines():
        # -Oqn gives "<oid> <value>" per row.
        idx = line.find(" ")
        if idx < 1:
            continue
        out.append({"oid": line[:idx], "value": line[idx + 1:]})
    return out


def _discover_sensors(ctx, params):
    """Discovery for supermicro_sensors: enumerate sensor names."""
    rows = _snmp_walk(ctx, params, SENSORS_BASE + ".2")
    sensors = []
    for r in rows:
        # The sensor name is the value of column .2 at this index.
        name = r["value"]
        if name == "":
            continue
        sensors.append({
            "item": name,
            "params": {"warn": None, "crit": None},
            "metrics": ["reading"],
        })
    return sensors


def _read_sensor_row(ctx, params, index):
    """Read all columns for a single sensor index."""
    name = _snmp_get(ctx, params, SENSORS_BASE + ".2." + index)
    if name == None:
        return None
    sensor_type = _snmp_get(ctx, params, SENSORS_BASE + ".3." + index)
    reading = _snmp_get(ctx, params, SENSORS_BASE + ".4." + index)
    high = _snmp_get(ctx, params, SENSORS_BASE + ".5." + index)
    low = _snmp_get(ctx, params, SENSORS_BASE + ".6." + index)
    unit = _snmp_get(ctx, params, SENSORS_BASE + ".11." + index)
    dev_status = _snmp_get(ctx, params, SENSORS_BASE + ".12." + index)
    if reading == None or sensor_type == None or dev_status == None:
        return None
    return {
        "name": name,
        "sensor_type": sensor_type,
        "reading": reading,
        "high": high,
        "low": low,
        "unit": unit,
        "dev_status": dev_status,
    }


def _worst_status(*args):
    """Pick the worst status code from the given numeric codes."""
    order = WORST_ORDER
    present = [a for a in args if a != None]
    if len(present) == 0:
        return 0
    worst = sorted(present, key=lambda x: order[x], reverse=True)[0]
    return worst


def _expect_order(*args):
    """Compute the ordinal position of the reading relative to sorted thresholds."""
    if len(args) == 0:
        return 0
    sorted_args = sorted(args)
    # find index of the first arg in the sorted list
    target = args[0]
    for i in range(len(sorted_args)):
        if sorted_args[i] == target:
            return i
    return 0


def _check_sensor(ctx, params, item):
    """Check one sensor item against thresholds and device status."""
    rows = _snmp_walk(ctx, params, SENSORS_BASE + ".2")
    index_found = None
    for r in rows:
        if r["value"] == item:
            # index is the suffix of the walked OID after the column base
            col_oid = SENSORS_BASE + ".2"
            if r["oid"].startswith(col_oid + "."):
                index_found = r["oid"][len(col_oid) + 1:]
                break
    if index_found == None:
        return {
            "changed": False,
            "msg": "no such sensor: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    row = _read_sensor_row(ctx, params, index_found)
    if row == None:
        return {
            "changed": False,
            "msg": "could not read sensor data: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    if not _is_int(row["reading"]):
        return {
            "changed": False,
            "msg": "invalid reading: " + row["reading"],
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    reading_f = float(row["reading"])
    if not _is_int(row["dev_status"]):
        return {
            "changed": False,
            "msg": "invalid device status: " + row["dev_status"],
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    dev_status_i = int(row["dev_status"])

    # thresholds derived from high/low if present
    crit_upper = None
    warn_upper = None
    crit_lower = None
    warn_lower = None
    status_high = 0
    status_low = 0
    if row["high"] != None and row["high"] != "":
        if _is_int(row["high"]):
            crit_upper = float(row["high"])
            warn_upper = crit_upper * 0.95
            status_high = _expect_order(reading_f, warn_upper, crit_upper)
    if row["low"] != None and row["low"] != "":
        if _is_int(row["low"]):
            crit_lower = float(row["low"])
            warn_lower = crit_lower * 1.05
            status_low = _expect_order(crit_lower, warn_lower, reading_f)

    perfvar = None
    display_reading = reading_f
    unit = row["unit"] if row["unit"] != None else ""

    if row["sensor_type"] == SENSOR_TYPE_TEMPERATURE:
        unit = "\u00b0" + unit
        perfvar = "temp"
    elif row["sensor_type"] == SENSOR_TYPE_VOLTAGE:
        if unit == "mV":
            reading_f = reading_f / 1000.0
            display_reading = reading_f
            if crit_upper != None:
                crit_upper = crit_upper / 1000.0
                warn_upper = warn_upper / 1000.0
            unit = "V"
        perfvar = "voltage"
    elif row["sensor_type"] == SENSOR_TYPE_STATUS:
        display_reading = "State " + str(int(reading_f))
        unit = ""

    worst = _worst_status(status_high, status_low, dev_status_i)
    state = HEALTH_STATE_MAP.get(worst, "UNKNOWN")

    metrics = {}
    if perfvar != None:
        metrics[perfvar] = reading_f

    msg = str(display_reading) + unit
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": ""},
    }


def _discover_health(ctx, params):
    """Discovery for the overall supermicro health (single-service)."""
    return [{
        "item": "",
        "params": {"warn": None, "crit": None},
        "metrics": [],
    }]


def _check_health(ctx, params):
    """Check overall hardware health from OID .2.3."""
    val = _snmp_get(ctx, params, HEALTH_BASE + ".3")
    if val == None:
        return {
            "changed": False,
            "msg": "no supermicro health data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    if not _is_int(val):
        return {
            "changed": False,
            "msg": "invalid health code: " + str(val),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    code = int(val)
    state = HEALTH_STATE_MAP.get(code, "UNKNOWN")
    return {
        "changed": False,
        "msg": "Overall: " + state,
        "data": {"state": state, "metrics": {}, "details": ""},
    }


def _discover_smart(ctx, params):
    """Discovery for supermicro SMART health items (per-disk)."""
    rows = _snmp_walk(ctx, params, SMART_BASE + ".2")
    items = []
    for r in rows:
        name = r["value"].replace("\\\\.\\", "")
        if name == "":
            continue
        items.append({
            "item": name,
            "params": {"warn": None, "crit": None},
            "metrics": [],
        })
    return items


def _check_smart(ctx, params, item):
    """Check one SMART disk against its status code."""
    rows = _snmp_walk(ctx, params, SMART_BASE + ".2")
    for r in rows:
        name = r["value"].replace("\\\\.\\", "")
        col_oid = SMART_BASE + ".2"
        if not r["oid"].startswith(col_oid + "."):
            continue
        index = r["oid"][len(col_oid) + 1:]
        if name != item:
            continue
        serial = _snmp_get(ctx, params, SMART_BASE + ".1." + index)
        status = _snmp_get(ctx, params, SMART_BASE + ".4." + index)
        if status == None:
            return {
                "changed": False,
                "msg": "could not read SMART status for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        state = SMART_STATUS_MAP.get(status, "UNKNOWN")
        label = SMART_LABEL_MAP.get(status, "Unknown")
        serial_str = serial if serial != None else "unknown"
        return {
            "changed": False,
            "msg": "(S/N " + serial_str + ") " + label,
            "data": {"state": state, "metrics": {}, "details": ""},
        }
    return {
        "changed": False,
        "msg": "no such SMART disk: " + item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }


def main(ctx, params):
    check_name = params.get("check_name", "supermicro_sensors")

    # Discovery mode: enumerate items.
    if params.get("_discover"):
        if not _snmp_present(ctx, params):
            return {"changed": False, "msg": "no supermicro hardware found",
                    "data": {"discovery": []}}
        if check_name == "supermicro_sensors":
            discovery = _discover_sensors(ctx, params)
        elif check_name == "supermicro_smart":
            discovery = _discover_smart(ctx, params)
        else:
            # overall health is single-service (item "")
            discovery = _discover_health(ctx, params)
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    # Check mode: evaluate one item.
    item = params.get("item", "")
    if not _snmp_present(ctx, params):
        return {
            "changed": False,
            "msg": "no supermicro hardware found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    if check_name == "supermicro_sensors":
        return _check_sensor(ctx, params, item)
    elif check_name == "supermicro_smart":
        return _check_smart(ctx, params, item)
    else:
        return _check_health(ctx, params)