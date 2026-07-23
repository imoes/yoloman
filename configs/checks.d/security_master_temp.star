def main(ctx, params):
    # ===== discovery mode =====
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.4.1.35491.30"

        # Fetch the SNMP table: OIDEnd (sensor number suffix) + sensor name at .3
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            base_oid, base_oid + ".30.3"
        ], mutates=False)

        # Parse for sensor numbers and names
        sensors = []
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split(" = ", 2)
            if len(parts) < 2:
                continue
            oid_full, value = parts[0], parts[1].strip()
            # Look for sensor name entries at *.30.3.1.X.5.0 -> .30.3.1.<X>.5.0
            # OID structure: .1.3.6.1.4.1.35491.30.3.1.<X>.5.0
            # We match suffix .5.0 at the end
            if oid_full.endswith(".5.0"):
                # Extract sensor number from OID: base_oid + ".30.3.1." + <X> + ".5.0"
                if ".30.3.1." in oid_full:
                    sensor_num_str = oid_full.split(".30.3.1.")[1].split(".5.0")[0]
                    sensor_num = int(sensor_num_str) if sensor_num_str.isdigit() else -1
                    # Remove quotes and leading/trailing whitespace
                    name = value.strip().strip('"')
                    if name == "":
                        name = "Sensor " + str(sensor_num)
                    # Only analog temp (ID 50) is monitored by this check
                    sensors.append({"item": str(sensor_num) + " " + name,
                                    "params": {},
                                    "metrics": ["temp"]})

        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(sensors),
            "data": {"discovery": sensors},
        }

    # ===== check mode =====
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item provided",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.35491.30"

    # We need: value (.2), sensor_id (.1), warn_low (.8), warn_high (.9), crit_low (.7), crit_high (.10)
    # Build per-sensor OIDs for this item's sensor number (first number before space in item)
    parts = item.split(" ", 1)
    if len(parts) < 1:
        return {
            "changed": False,
            "msg": "invalid item format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    sensor_num_str = parts[0]
    if not sensor_num_str.isdigit():
        return {
            "changed": False,
            "msg": "item number is not an integer",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    sensor_num = int(sensor_num_str)

    # Helper to get a single OID value
    def get_oid_value(oid_base):
        res = ctx.run([
            "snmpget", "-v2c", "-c", community, "-On", host, oid_base
        ], mutates=False)
        if res.rc != 0:
            return None
        # Parse "OID = STRING: value" or "OID = INTEGER: value"
        for line in res.stdout.splitlines():
            line = line.strip()
            if "=" in line:
                oid_full, val_part = line.split("=", 1)
                return val_part.strip()
        return None

    oid_base_root = base_oid + ".30.3.1." + str(sensor_num)
    oid_value      = oid_base_root + ".2.0"
    oid_sensor_id  = oid_base_root + ".1.0"
    oid_warn_low   = oid_base_root + ".8.0"
    oid_warn_high  = oid_base_root + ".9.0"
    oid_crit_low   = oid_base_root + ".7.0"
    oid_crit_high  = oid_base_root + ".10.0"

    # Fetch all values
    value_str      = get_oid_value(oid_value)
    sensor_id_str  = get_oid_value(oid_sensor_id)
    warn_low_str   = get_oid_value(oid_warn_low)
    warn_high_str  = get_oid_value(oid_warn_high)
    crit_low_str   = get_oid_value(oid_crit_low)
    crit_high_str  = get_oid_value(oid_crit_high)

    # Convert
    def parse_float(s):
        if s == None:
            return None
        s_stripped = s.strip()
        # Allow digits, dot, minus sign
        cleaned = ""
        for c in s_stripped:
            if c.isdigit() or c == "." or c == "-":
                cleaned = cleaned + c
            else:
                break
        return float(cleaned) if cleaned != "" and cleaned.replace(".","").replace("-","").isdigit() else None

    value = parse_float(value_str)
    warn_high_snmp = parse_float(warn_high_str)
    warn_low_snmp  = parse_float(warn_low_str)
    crit_high_snmp = parse_float(crit_high_str)
    crit_low_snmp  = parse_float(crit_low_str)

    # Sensor ID must be 50 for temperature
    sensor_id = int(sensor_id_str) if sensor_id_str and sensor_id_str.isdigit() else None
    if sensor_id != 50:
        return {
            "changed": False,
            "msg": "sensor is not a temperature sensor (ID %s)" % str(sensor_id),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Missing value -> UNKNOWN
    if value == None:
        return {
            "changed": False,
            "msg": "sensor value not available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Threshold defaults from params and SNMP-provided levels
    levels = params.get("levels", (None, None))
    levels_lower = params.get("levels_lower", (None, None))

    # If params levels are missing, use SNMP
    if levels == (None, None):
        levels = (warn_high_snmp, crit_high_snmp) if crit_high_snmp != None else (warn_high_snmp, warn_high_snmp)
    if levels_lower == (None, None):
        levels_lower = (warn_low_snmp, crit_low_snmp) if crit_low_snmp != None else (warn_low_snmp, warn_low_snmp)

    # Check thresholds: higher first, then lower
    state = "OK"
    reason = ""

    if levels and levels[1] != None and value >= levels[1]:  # crit_high
        state = "CRIT"
        reason = "Critical: %f C >= %f C" % (value, levels[1])
    elif levels and levels[0] != None and value >= levels[0]:  # warn_high
        state = "WARN"
        reason = "Warning: %f C >= %f C" % (value, levels[0])
    elif levels_lower and levels_lower[1] != None and value <= levels_lower[1]:  # crit_low
        state = "CRIT"
        reason = "Critical: %f C <= %f C" % (value, levels_lower[1])
    elif levels_lower and levels_lower[0] != None and value <= levels_lower[0]:  # warn_low
        state = "WARN"
        reason = "Warning: %f C <= %f C" % (value, levels_lower[0])

    if state == "OK":
        reason = "Temperature: %f C" % value

    return {
        "changed": False,
        "msg": reason,
        "data": {
            "state": state,
            "metrics": {"temp": value},
            "details": "",
        },
    }