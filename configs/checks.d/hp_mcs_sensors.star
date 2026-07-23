# ===== Starlark check module: hp_mcs_sensors =====
# Read-only: never mutates=True, never writes to disk

_TEMP_TYPES = [4, 5, 13, 14, 15, 16, 17, 18, 19, 20]
_FAN_TYPES = [9, 10, 11, 26, 27, 28]
_SNMP_OID_BASE = ".1.3.6.1.4.1.232.167.2.4.5.2.1"
_SNMP_OID_ID = "1"
_SNMP_OID_TYPE = "2"
_SNMP_OID_NAME = "3"
_SNMP_OID_STATUS = "4"
_SNMP_OID_VALUE = "5"
_SNMP_OID_HIGH = "6"
_SNMP_OID_LOW = "7"

def _parse_snmp_section(ctx, community, host):
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community,
        "-On", host, _SNMP_OID_BASE
    ], mutates=False)
    lines = res.stdout.splitlines()
    section = {}
    for line in lines:
        # Format: OID.index = STRING: value OR INTEGER: value
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_full, val_raw = parts
        # Extract index (last part after last dot)
        oid_parts = oid_full.split(".")
        if len(oid_parts) < 2:
            continue
        index = oid_parts[-1]
        # Parse value (strip type prefix like "INTEGER: " or "STRING: ")
        val_str = val_raw.strip()
        if val_str.startswith("INTEGER: "):
            val = int(val_str[9:])
        elif val_str.startswith("STRING: "):
            val = val_str[8:].strip().strip('"')
        elif val_str.startswith("Gauge32: "):
            val = float(val_str[9:])
        else:
            continue

        # Build section keyed by index
        if index not in section:
            section[index] = {}
        # Map OID suffixes to keys
        if oid_full.endswith("." + _SNMP_OID_ID):
            section[index]["id"] = val
        elif oid_full.endswith("." + _SNMP_OID_TYPE):
            section[index]["type"] = val
        elif oid_full.endswith("." + _SNMP_OID_NAME):
            section[index]["name"] = val
        elif oid_full.endswith("." + _SNMP_OID_STATUS):
            section[index]["status"] = val
        elif oid_full.endswith("." + _SNMP_OID_VALUE):
            section[index]["value"] = val
        elif oid_full.endswith("." + _SNMP_OID_HIGH):
            section[index]["high"] = val
        elif oid_full.endswith("." + _SNMP_OID_LOW):
            section[index]["low"] = val

    return section

def _discover_sensors(section, sensor_type_set):
    items = []
    for key, entry in section.items():
        t = entry.get("type")
        if t != None:
            found = False
            for allowed in sensor_type_set:
                if t == allowed:
                    found = True
                    break
            if found:
                name = entry.get("name", "")
                if name != "":
                    items.append({
                        "item": name,
                        "params": {"levels": (70, 80)},
                        "metrics": ["temperature"]
                    })
    return items

def _discover_fans(section):
    return _discover_sensors(section, _FAN_TYPES)

def _check_temperature(item, params, section):
    for key, entry in section.items():
        if entry.get("name") == item:
            value = entry.get("value")
            if value == None:
                return {"state": "UNKNOWN", "msg": "no value for sensor %s" % item}
            levels = params.get("levels", (70, 80))
            warn = levels[0]
            crit = levels[1]
            if value >= crit:
                state = "CRIT"
            elif value >= warn:
                state = "WARN"
            else:
                state = "OK"
            return {
                "state": state,
                "msg": "temperature %f C" % value,
                "metrics": {"temperature": value},
                "details": "high: %f, low: %f" % (
                    entry.get("high", 0), entry.get("low", 0)
                )
            }
    return {"state": "UNKNOWN", "msg": "sensor not found: %s" % item}

def _check_fan(item, params, section):
    for key, entry in section.items():
        if entry.get("name") == item:
            value = entry.get("value")
            if value == None:
                return {"state": "UNKNOWN", "msg": "no value for fan sensor %s" % item}
            lower = params.get("lower", (1000, 500))
            warn = lower[0]
            crit = lower[1]
            if value <= crit:
                state = "CRIT"
            elif value <= warn:
                state = "WARN"
            else:
                state = "OK"
            return {
                "state": state,
                "msg": "speed %f RPM" % value,
                "metrics": {"fan_speed": value},
                "details": ""
            }
    return {"state": "UNKNOWN", "msg": "fan sensor not found: %s" % item}

def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        section = _parse_snmp_section(ctx, community, host)
        # Discover temperature sensors first
        temp_items = _discover_sensors(section, _TEMP_TYPES)
        fan_items = _discover_fans(section)
        all_items = temp_items + fan_items
        return {
            "changed": False,
            "msg": "discovered %d sensors" % len(all_items),
            "data": {"discovery": all_items}
        }

    # Check mode: single item
    item = params.get("item", "")
    section = _parse_snmp_section(ctx, community, host)

    # Determine sensor type from section data
    sensor_type = None
    for key, entry in section.items():
        if entry.get("name") == item:
            sensor_type = entry.get("type")
            break

    if sensor_type != None:
        found_temp = False
        found_fan = False
        for t in _TEMP_TYPES:
            if sensor_type == t:
                found_temp = True
                break
        for t in _FAN_TYPES:
            if sensor_type == t:
                found_fan = True
                break
        if found_temp:
            res = _check_temperature(item, params, section)
        elif found_fan:
            res = _check_fan(item, params, section)
        else:
            res = {"state": "UNKNOWN", "msg": "sensor type unknown or not found: %s" % item}
    else:
        res = {"state": "UNKNOWN", "msg": "sensor type unknown or not found: %s" % item}

    return {
        "changed": False,
        "msg": res.get("msg", "unknown error"),
        "data": {
            "state": res.get("state", "UNKNOWN"),
            "metrics": res.get("metrics", {}),
            "details": res.get("details", "")
        }
    }