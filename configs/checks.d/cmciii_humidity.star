# ===== module constants (defined at top level) =====

# Sensor type key in the parsed section
SENSOR_TYPE = "humidity"

# Default discovery parameter
DEFAULT_USE_SENSOR_DESCRIPTION = False

# Mapping from JSON sensor status string to Starlark State
STATUS_MAP = {
    "OK": "OK",
    "CRIT": "CRIT",
    "WARN": "WARN",
    "UNKNOWN": "UNKNOWN",
}


def _parse_snmp_output(stdout):
    """Parse snmpwalk-style output into dict of sensors.

    Expected format per line:
    OID = STRING: "value"  -> we extract the value string
    or
    OID = INTEGER: value   -> we extract the integer

    But for CMCIII humidity we expect:
      - .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6.<n>.0 = STRING: "<id>"
      - .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6.<n>.1 = STRING: "<DescName>"
      - .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6.<n>.2 = INTEGER: <Value>
      - .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6.<n>.3 = STRING: "<Status>"
      - .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6.<n>.4 = STRING: "<Location>"
      - .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6.<n>.5 = INTEGER: <Index>
    We build a dict:
      section["humidity"][id_] = {
        "DescName": ..., "Value": ..., "Status": ..., "_location_": ..., "_index_": ...
      }
    """
    lines = stdout.splitlines() if stdout else []
    # Base OID for humidity sensors
    base_oid = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6"
    humidity = {}
    for line in lines:
        if not line or "=" not in line:
            continue
        # Split OID and value parts
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid, value_part = parts
        if not oid.startswith(base_oid):
            continue
        suffix = oid[len(base_oid):]
        if not suffix.startswith("."):
            continue
        # Extract sensor index and field index
        suffix = suffix[1:]  # strip leading dot
        idx_dot = suffix.find(".")
        if idx_dot == -1:
            continue
        sensor_idx = suffix[:idx_dot]
        field_idx = suffix[idx_dot+1:]
        # Strip trailing .0 if present (some agents add it)
        if field_idx.endswith(".0"):
            field_idx = field_idx[:-2]
        # Guard against non-integer field index
        if not field_idx.isdigit():
            continue
        field_idx_int = int(field_idx)
        # Extract value (strip quotes and type prefix)
        value_part = value_part.strip()
        # Remove type prefix (STRING:, INTEGER:, etc.)
        val = None
        if value_part.startswith("STRING:"):
            val = value_part[7:]
            val = val.strip('"')
        elif value_part.startswith("INTEGER:"):
            val_str = value_part[8:].strip()
            if val_str.isdigit() or (val_str.startswith("-") and val_str[1:].isdigit()):
                val = int(val_str)
            else:
                val = val_str
        else:
            val = value_part
        # Initialize sensor entry if needed
        if sensor_idx not in humidity:
            humidity[sensor_idx] = {"_location_": "", "_index_": 0}
        # Map field index to key
        if field_idx_int == 0:
            humidity[sensor_idx]["Id"] = val
        elif field_idx_int == 1:
            humidity[sensor_idx]["DescName"] = val
        elif field_idx_int == 2:
            humidity[sensor_idx]["Value"] = val
        elif field_idx_int == 3:
            humidity[sensor_idx]["Status"] = val
        elif field_idx_int == 4:
            humidity[sensor_idx]["_location_"] = val
        elif field_idx_int == 5:
            humidity[sensor_idx]["_index_"] = val
    return {"humidity": humidity}


def main(ctx, params):
    if params.get("_discover"):
        # Discovery: walk humidity sensor OID
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6"
        ], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP walk failed: " + res.stderr,
                "data": {"discovery": []}
            }
        section = _parse_snmp_output(res.stdout)
        # Only humidity sensors
        sensors = section.get(SENSOR_TYPE, {})
        use_desc = params.get("use_sensor_description", DEFAULT_USE_SENSOR_DESCRIPTION)
        discovered = []
        for id_, entry in sensors.items():
            # Build item name
            if use_desc and entry.get("DescName"):
                item = "{}-{} {}".format(entry.get("_location_", ""), entry.get("_index_", ""), entry.get("DescName", ""))
            else:
                item = id_
            # Suggested default parameters: empty (no thresholds set by default)
            # We'll pass _item_key so get_sensor can find it
            discovered.append({
                "item": item,
                "params": {"_item_key": id_},
                "metrics": ["humidity", "status"]
            })
        return {
            "changed": False,
            "msg": "discovered %d humidity sensors" % len(discovered),
            "data": {"discovery": discovered}
        }

    # Check mode: single item
    item = params.get("item", "")
    # Get sensor id from discovered params if available
    item_key = params.get("_item_key", item)
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6"
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP data unavailable: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    section = _parse_snmp_output(res.stdout)
    sensors = section.get(SENSOR_TYPE, {})
    entry = sensors.get(item_key)
    if not entry:
        return {
            "changed": False,
            "msg": "humidity sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Get status
    status_readable = entry.get("Status", "UNKNOWN")
    if status_readable == "OK":
        state = "OK"
    else:
        state = "CRIT"
    summary = "Status: %s" % status_readable

    # Humidity value
    humidity = 0.0
    if entry.get("Value") != None:
        val = entry["Value"]
        humidity = float(val) if type(val) == "int" or type(val) == "float" or (type(val) == "string" and val.replace(".", "").replace("-", "").isdigit()) else 0.0

    # Thresholds: check_humidity uses default levels (none by default) -> we assume no thresholds
    warn = params.get("warn")
    crit = params.get("crit")
    # If levels provided, use them; otherwise no thresholds -> state stays OK unless status is bad
    if warn != None or crit != None:
        if crit != None and humidity >= float(crit):
            state = "CRIT"
        elif warn != None and humidity >= float(warn):
            state = "WARN"

    metrics = {"humidity": humidity}
    details = "Humidity: %f%%" % humidity

    return {
        "changed": False,
        "msg": summary + ", " + details,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": details
        }
    }
