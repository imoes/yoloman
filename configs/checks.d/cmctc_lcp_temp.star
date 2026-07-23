# Map from status code to (checkmk_state, description)
_MAP_SENSOR_STATE = {
    "1": (3, "not available"),
    "2": (2, "lost"),
    "3": (1, "changed"),
    "4": (0, "ok"),
    "5": (2, "off"),
    "6": (0, "on"),
    "7": (1, "warning"),
    "8": (2, "too low"),
    "9": (2, "too high"),
    "10": (2, "error"),
}

# Map from sensor type to unit string
_MAP_UNIT = {
    "access": "",
    "current": " A",
    "status": "",
    "position": "",
    "temp": " °C",
    "blower": " RPM",
    "blowergrade": "",
    "humidity": "%",
    "flow": " l/min",
    "regulator": "%",
    "user": "",
}

# Sensor type mapping from typeid -> (description_prefix, sensor_type)
_CMCTC_LCP_SENSORS = {
    "4": (None, "access"),
    "12": (None, "humidity"),
    "13": ("normally open", "user"),
    "14": ("normally closed", "user"),
    "23": (None, "flow"),
    "30": (None, "current"),
    "31": (None, "status"),
    "32": (None, "position"),
    "40": ("1", "blower"),
    "41": ("2", "blower"),
    "42": ("3", "blower"),
    "43": ("4", "blower"),
    "44": ("5", "blower"),
    "45": ("6", "blower"),
    "46": ("7", "blower"),
    "47": ("8", "blower"),
    "48": ("Server in 1", "temp"),
    "49": ("Server out 1", "temp"),
    "50": ("Server in 2", "temp"),
    "51": ("Server out 2", "temp"),
    "52": ("Server in 3", "temp"),
    "53": ("Server out 3", "temp"),
    "54": ("Server in 4", "temp"),
    "55": ("Server out 4", "temp"),
    "56": ("Overview Server in", "temp"),
    "57": ("Overview Server out", "temp"),
    "58": ("Water in", "temp"),
    "59": ("Water out", "temp"),
    "60": (None, "flow"),
    "61": (None, "blowergrade"),
    "62": (None, "regulator"),
}

# SNMP base OIDs per tree index
_TREES = ["3", "4", "5", "6"]


def _translate_status(status):
    """
    Map raw status code to checkmk state and text.
    Checkmk states: 0=OK, 1=WARN, 2=CRIT, 3=UNKNOWN
    """
    s = int(status) if status.isdigit() else 0
    if s == 4:
        return 0, "ok"
    elif s == 7:
        return 1, "warning"
    elif s == 8:
        return 1, "tooLow"
    elif s == 9:
        return 2, "tooHigh"
    else:
        return 3, "UNKNOWN"


def _translate_status_text(status):
    """
    Map raw status code to status text.
    """
    s = int(status) if status.isdigit() else 0
    texts = {
        1: "notAvail",
        2: "lost",
        3: "changed",
        4: "ok",
        5: "off",
        6: "on",
        7: "warning",
        8: "tooLow",
        9: "tooHigh",
    }
    return texts.get(s, "UNKNOWN")


def _parse_snmp_line(line):
    """
    Parse a single snmpwalk line into (oid, value).
    Returns (oid_parts, value_str) or None if invalid.
    """
    if not line or " = " not in line:
        return None
    parts = line.strip().split(" = ", 1)
    if len(parts) != 2:
        return None
    oid_full = parts[0]
    value_raw = parts[1]
    # Split OID by dots
    oid_parts = oid_full.split(".")
    # Value extraction
    if value_raw.startswith("INTEGER: "):
        value = value_raw[len("INTEGER: "):]
    elif value_raw.startswith("STRING: "):
        value = value_raw[len("STRING: "):].strip('"')
    else:
        value = value_raw.strip('"')
    return (oid_parts, value)


def _gather_section(ctx):
    """
    Gather all sensors via SNMP.
    Returns dict: {item: sensor} with fields:
      status, reading, high, low, warn, description, type_
    """
    all_sensors = {}
    for tree in _TREES:
        base_oid = ".1.3.6.1.4.1.2606.4.2." + tree + ".5.2.1"
        res = ctx.run(["snmpwalk", "-v2c", "-c", "public", "-On", "localhost", base_oid], mutates=False)
        if not res.stdout:
            continue
        rows_dict = {}
        for line in res.stdout.splitlines():
            parsed = _parse_snmp_line(line)
            if parsed == None:
                continue
            oid_parts, value = parsed
            # OID structure: ...base...5.2.1.{index}.{col}
            if len(oid_parts) < 11:
                continue
            # Extract index and col from last two parts
            idx_part = oid_parts[-2]
            col_part = oid_parts[-1]
            # Guard against invalid parts
            if not (idx_part.isdigit() and col_part.isdigit()):
                continue
            idx = int(idx_part)
            col = int(col_part)
            key = (tree, idx)
            if key not in rows_dict:
                rows_dict[key] = {}
            rows_dict[key][col] = value
        # Build final rows
        for (tree, idx), cols in sorted(rows_dict.items()):
            typeid = cols.get(2)
            status = cols.get(4)
            reading = cols.get(5)
            high = cols.get(6)
            low = cols.get(7)
            warn_val = cols.get(8)
            description = cols.get(9)
            if typeid == None or typeid == "":
                continue
            sensor_spec = _CMCTC_LCP_SENSORS.get(typeid)
            if sensor_spec == None:
                continue
            if sensor_spec[0] != None and sensor_spec[0]:
                item = sensor_spec[0] + " - " + tree + "." + str(idx)
            else:
                item = tree + "." + str(idx)
            sensor = {
                "status": status if status != None else "0",
                "reading": float(reading) if reading != None and reading.isdigit() else 0.0,
                "high": float(high) if high != None and high.isdigit() else 0.0,
                "low": float(low) if low != None and low.isdigit() else 0.0,
                "warn": float(warn_val) if warn_val != None and warn_val.isdigit() else 0.0,
                "description": description if description != None else "",
                "type_": sensor_spec[1],
            }
            all_sensors[item] = sensor
    return all_sensors


def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        section = _gather_section(ctx)
        # Filter for temperature sensors only (type_ == "temp")
        discovery_items = []
        for item, sensor in section.items():
            if sensor.get("type_") == "temp":
                # Suggest default temperature levels
                discovery_items.append({
                    "item": item,
                    "params": {"levels": [25.0, 30.0]},  # default warn/crit (°C) — Checkmk default
                    "metrics": ["temp"]
                })
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }

    # Check mode
    item = params.get("item", "")
    section = _gather_section(ctx)
    sensor = section.get(item)
    if sensor == None:
        return {
            "changed": False,
            "msg": "temperature sensor not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Extract sensor values
    reading = sensor["reading"]
    high = sensor["high"]
    low = sensor["low"]
    warn_val = sensor["warn"]
    status = sensor["status"]
    description = sensor["description"]
    sensor_type = sensor.get("type_", "temp")
    unit = _MAP_UNIT.get(sensor_type, "")

    # Translate sensor status to checkmk state and text
    checkmk_state_raw, status_text = _translate_status(status)
    # Use default params for temperature levels if not provided
    default_levels = params.get("levels", [25.0, 30.0])
    warn_param = default_levels[0]
    crit_param = default_levels[1]

    # Build info text
    extra_info = ""
    if description != None and description:
        extra_info = "[" + description + "] "
    info_text = extra_info + str(int(reading)) + unit

    # Compute state based on levels
    state = "OK"
    if params.get("levels") != None:
        warn_val = default_levels[0]
        crit_val = default_levels[1]
        if reading >= crit_val:
            state = "CRIT"
            extra_info += " (warn/crit at %d/%d%s)" % (warn_val, crit_val, unit)
        elif reading >= warn_val:
            state = "WARN"
            extra_info += " (warn/crit at %d/%d%s)" % (warn_val, crit_val, unit)
    else:
        # Use device levels (low/high) if no params
        if high != 0.0 or low != 0.0:
            if reading >= high or reading <= low:
                state = "CRIT"
                extra_info += " (device lower/upper crit at %d/%d%s)" % (low, high, unit)

    return {
        "changed": False,
        "msg": info_text,
        "data": {
            "state": state,
            "metrics": {"temp": reading},
            "details": extra_info.strip()
        }
    }