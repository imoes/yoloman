# Top-level constants (no imports, no re)
SENSOR_TYPE_NAMES = {
    "0": "undefined",
    "1": "temperature",
    "2": "humidity",
    "3": "power",
    "4": "lowVoltage",
    "5": "current",
    "6": "aclmvVoltage",
    "7": "aclmpVoltage",
    "8": "aclmpPower",
    "9": "water",
    "10": "smoke",
    "11": "vibration",
    "12": "motion",
    "13": "glass",
    "14": "door",
    "15": "keypad",
    "16": "panicButton",
    "17": "keyStation",
    "18": "digInput",
    "22": "light",
    "24": "dewpoint",
    "26": "tacDio",
    "36": "acVoltage",
    "37": "acCurrent",
    "38": "dcVoltage",
    "39": "dcCurrent",
    "41": "rmsVoltage",
    "42": "rmsCurrent",
    "43": "activePower",
    "44": "reactivePower",
    "513": "tempHum",
    "32767": "custom",
    "32769": "temperatureCombo",
    "32770": "humidityCombo",
    "540": "tempHum",
}

# Checkmk defaults for humidity checks (from ENVIROMUX_CHECK_DEFAULT_PARAMETERS)
DEFAULT_HUM_WARN = 60.0
DEFAULT_HUM_CRIT = 70.0

def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On",
            host,
            ".1.3.6.1.4.1.3699.1.1.2.1.5.1.1"
        ], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)
        
        # Parse SNMP output into lines of key=value pairs
        lines = res.stdout.splitlines()
        sensors = {}
        # Map OID suffixes to field indices
        # base OID + suffix (1..12)
        # We'll group by sensor index (oid suffix 1)
        current_index = ""
        data = {}
        for line in lines:
            line = line.strip()
            if not line:
                continue
            # Format: OID = STRING: value or OID = INTEGER: value
            eq_pos = line.find("=")
            if eq_pos < 0:
                continue
            oid_full = line[:eq_pos].strip()
            value_part = line[eq_pos+1:].strip()
            # Extract suffix after base
            if not oid_full.startswith(".1.3.6.1.4.1.3699.1.1.2.1.5.1.1."):
                continue
            suffix = oid_full[len(".1.3.6.1.4.1.3699.1.1.2.1.5.1.1."):].strip()
            # Remove potential leading zeros for numeric suffixes
            if suffix.isdigit():
                suffix_int = int(suffix)
            else:
                continue
            
            # Value parsing
            if value_part.startswith('"') and value_part.endswith('"'):
                value = value_part[1:-1]
            elif ":" in value_part:
                value = value_part.split(":", 1)[1].strip()
            else:
                value = value_part
            
            # Group by sensor index (suffix 1)
            if suffix_int == 1:
                current_index = value
                data[current_index] = {}
            if current_index and suffix_int in [2, 3, 7, 11, 12]:
                data[current_index][suffix_int] = value
        
        # Now parse the sensor data and discover humidity sensors
        discovered = []
        for idx, fields in data.items():
            sensor_type_raw = fields.get(2, "")
            description = fields.get(3, "")
            sensor_type_name = SENSOR_TYPE_NAMES.get(sensor_type_raw, "unknown")
            # Humidity types: "humidity" or "humidityCombo"
            if sensor_type_name in ["humidity", "humidityCombo"]:
                item_name = description + " " + idx
                discovered.append({
                    "item": item_name,
                    "params": {"levels": (DEFAULT_HUM_WARN, DEFAULT_HUM_CRIT)},
                    "metrics": ["humidity"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d humidity sensors" % len(discovered),
            "data": {"discovery": discovered}
        }
    
    # Check mode: single item
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Query specific sensor via snmpget
    # Base OID: .1.3.6.1.4.1.3699.1.1.2.1.5.1.1
    # We need to find the sensor index that matches the item description + index
    # Parse item: "description index"
    parts = item.rsplit(" ", 1)
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "invalid item format: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    desc, idx = parts
    base_oid = ".1.3.6.1.4.1.3699.1.1.2.1.5.1.1."
    
    # Get the required fields: type (2), description (3), value (7), min (11), max (12)
    # Use snmpget for each OID
    def snmp_get(oid_suffix):
        res = ctx.run([
            "snmpget",
            "-v2c",
            "-c", community,
            "-On",
            host,
            base_oid + oid_suffix + "." + idx
        ], mutates=False)
        return res
    
    res_type = snmp_get("2")
    res_desc = snmp_get("3")
    res_val = snmp_get("7")
    res_min = snmp_get("11")
    res_max = snmp_get("12")
    
    # Check if we found the sensor: type must be present
    if res_type.rc != 0 or not res_type.stdout.strip():
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse value strings
    def parse_snmp_value(res):
        out = res.stdout.strip()
        if not out:
            return None
        # Format: OID = STRING: value or OID = INTEGER: value
        eq_pos = out.find("=")
        if eq_pos < 0:
            return None
        value_part = out[eq_pos+1:].strip()
        if value_part.startswith('"') and value_part.endswith('"'):
            return value_part[1:-1]
        elif ":" in value_part:
            return value_part.split(":", 1)[1].strip()
        else:
            return value_part
    
    type_raw = parse_snmp_value(res_type)
    sensor_type_name = SENSOR_TYPE_NAMES.get(type_raw, "unknown")
    value_str = parse_snmp_value(res_val)
    
    if sensor_type_name not in ["humidity", "humidityCombo"]:
        return {
            "changed": False,
            "msg": "sensor is not humidity type",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse humidity value
    humidity = None
    if value_str and value_str.replace(".", "", 1).lstrip("-").isdigit():
        humidity = float(value_str) / 10.0  # scaling factor for humidity? Check source: humidity does NOT have scaling.
        # In source: humidity sensors do NOT have scaling (only temp/power/current/... do)
        # Recheck: source says only ["temperature", "power", "current", "temperatureCombo"] are scaled by 10.
        # Humidity is not in that list, so no scaling.
        # Correction: humidity is "humidity", "humidityCombo" — no scaling applied.
        # Value is raw integer percent (e.g. 55), not scaled.
        humidity = float(value_str)
    
    # Parse thresholds (min_threshold = min (11), max_threshold = max (12))
    min_val_str = parse_snmp_value(res_min)
    max_val_str = parse_snmp_value(res_max)
    min_threshold = float(min_val_str) if min_val_str and min_val_str.replace(".", "", 1).lstrip("-").isdigit() else None
    max_threshold = float(max_val_str) if max_val_str and max_val_str.replace(".", "", 1).lstrip("-").isdigit() else None
    
    if humidity == None:
        return {
            "changed": False,
            "msg": "could not parse humidity value",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Extract thresholds from params
    levels = params.get("levels", (DEFAULT_HUM_WARN, DEFAULT_HUM_CRIT))
    warn = levels[0]
    crit = levels[1]
    
    # Humidity check: OK if warn <= humidity <= crit is NOT the rule.
    # Checkmk humidity checks: levels_upper = (warn, crit) for upper bound alert,
    # levels_lower for lower bound.
    # Standard behavior: humidity above crit -> CRIT, above warn -> WARN
    # Since humidity is percentage, higher is usually worse.
    # Checkmk's lib.humidity.check_humidity:
    #   - levels_upper = (warn, crit): warn if > warn, crit if > crit
    #   - levels_lower = (warn_l, crit_l): warn if < warn_l, crit if < crit_l
    
    # For now, assume only upper levels are set (default)
    state = "OK"
    details = ""
    
    # Check upper levels first
    if humidity >= crit:
        state = "CRIT"
        details = "Humidity is too high"
    elif humidity >= warn:
        state = "WARN"
        details = "Humidity is elevated"
    
    # If device provides thresholds, check those too (optional)
    # We'll keep the simple version: use params levels only
    # If min_threshold/max_threshold exist, we could check against device limits too
    # But source code for humidity does NOT use min_threshold/max_threshold — only temperature/voltage do.
    
    # Build metrics
    metrics = {"humidity": humidity}
    
    # Message: Checkmk-style
    msg = "Humidity: %f %% (warn at %f %%, crit at %f %%) %s" % (
        humidity, warn, crit, details)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": details
        }
    }