# Constants for SNMP OIDs
RA32E_BASE_INTERNAL = ".1.3.6.1.4.1.20916.1.8.1.1"
RA32E_BASE_DIGITAL = ".1.3.6.1.4.1.20916.1.8.1.2"
SNMP_OID_TEMP_CELSIUS = "1"
SNMP_OID_TEMP_FAHRENHEIT = "2"
SNMP_OID_HUMIDITY = "3"
SNMP_OID_HEAT_INDEX_FAHRENHEIT = "4"
SNMP_OID_HEAT_INDEX_CELSIUS = "5"

# Checkmk defaults
DEFAULT_WARN = 70.0
DEFAULT_CRIT = 80.0


def _snmpwalk(ctx, host, community, base_oid, sub_oid):
    """Walk a complete OID path and return parsed lines"""
    full_oid = base_oid + "." + sub_oid
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, full_oid], mutates=False)
    return res.stdout.splitlines()


def _parse_snmp_value(line):
    """Parse a single snmpwalk line: 'OID = STRING: value' -> value string"""
    if not line.strip():
        return None
    if "=" not in line:
        return None
    parts = line.split("=", 1)
    if len(parts) != 2:
        return None
    value_part = parts[1].strip()
    # Remove type prefix (e.g., "STRING: ", "INTEGER: ", etc.)
    if ":" in value_part:
        value_part = value_part.split(":", 1)[1].strip()
    # Remove surrounding quotes if present
    if value_part.startswith('"') and value_part.endswith('"'):
        value_part = value_part[1:-1]
    return value_part.strip()


def _gather_ra32e_section(ctx, host, community):
    """Gather internal and digital sections via SNMP"""
    # Internal: temp, humidity, heat_index
    internal_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-On", host,
         RA32E_BASE_INTERNAL + ".1", RA32E_BASE_INTERNAL + ".2", RA32E_BASE_INTERNAL + ".4.2"],
        mutates=False
    )
    # Parse internal section
    lines = internal_res.stdout.splitlines()
    internal = {"temperature": None, "humidity": None, "heat_index": None}
    if len(lines) >= 3:
        val1 = _parse_snmp_value(lines[0])
        val2 = _parse_snmp_value(lines[1])
        val3 = _parse_snmp_value(lines[2])
        if val1 and val1.isdigit():
            internal["temperature"] = float(val1) / 100.0
        if val2 and val2.isdigit():
            internal["humidity"] = float(val2) / 100.0
        if val3 and val3.isdigit():
            internal["heat_index"] = float(val3) / 100.0

    # Digital sensors (8 sensors)
    digital = []
    for i in range(1, 9):
        base = RA32E_BASE_DIGITAL + "." + str(i)
        # We only need temp (1), humidity (3), heat index (5)
        temp_oid = base + "." + SNMP_OID_TEMP_CELSIUS
        humidity_oid = base + "." + SNMP_OID_HUMIDITY
        heat_index_oid = base + "." + SNMP_OID_HEAT_INDEX_CELSIUS

        temp_val = None
        humidity_val = None
        heat_index_val = None

        # Get values in a single call to minimize roundtrips
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-On", host, temp_oid, humidity_oid, heat_index_oid],
            mutates=False
        )
        lines = res.stdout.splitlines()
        for line in lines:
            oid_val = _parse_snmp_value(line)
            if not oid_val:
                continue
            if line.startswith(temp_oid):
                if oid_val.isdigit():
                    temp_val = float(oid_val) / 100.0
            elif line.startswith(humidity_oid):
                # Humidity is percentage; might have decimal point, e.g., "45.0"
                # Guard against parsing non-numeric values
                if oid_val.replace(".", "", 1).isdigit():
                    humidity_val = float(oid_val)
                else:
                    humidity_val = None
            elif line.startswith(heat_index_oid):
                if oid_val.isdigit():
                    heat_index_val = float(oid_val) / 100.0

        if temp_val != None or humidity_val != None or heat_index_val != None:
            digital.append({
                "temperature": temp_val,
                "humidity": humidity_val,
                "heat_index": heat_index_val
            })
        else:
            digital.append(None)

    return {"internal": internal, "digital": digital}


def _get_item_name(item, digital_count):
    """Map Checkmk item to index"""
    if item == "Internal":
        return "internal", None
    if item.startswith("Sensor "):
        idx_str = item[7:]
        if idx_str.isdigit():
            idx = int(idx_str) - 1
            if (0 <= idx) and (idx < digital_count):
                return "digital", idx
    return None, None


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Discovery mode
    if params.get("_discover"):
        section = _gather_ra32e_section(ctx, host, community)
        out = []
        
        if section.get("internal") and section["internal"].get("humidity") != None:
            out.append({
                "item": "Internal",
                "params": {"warn": DEFAULT_WARN, "crit": DEFAULT_CRIT},
                "metrics": ["humidity"]
            })
        
        for i, digital_section in enumerate(section.get("digital", [])):
            if digital_section and digital_section.get("humidity") != None:
                item_name = "Sensor %d" % (i + 1)
                out.append({
                    "item": item_name,
                    "params": {"warn": DEFAULT_WARN, "crit": DEFAULT_CRIT},
                    "metrics": ["humidity"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d humidity sensors" % len(out),
            "data": {"discovery": out}
        }
    
    # Check mode
    item = params.get("item", "")
    warn = params.get("warn", DEFAULT_WARN)
    crit = params.get("crit", DEFAULT_CRIT)
    
    section = _gather_ra32e_section(ctx, host, community)
    
    item_type, idx = _get_item_name(item, len(section.get("digital", [])))
    
    if item_type == "internal":
        humidity = section.get("internal", {}).get("humidity")
        if humidity == None:
            return {
                "changed": False,
                "msg": "Internal humidity sensor not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
        value = humidity
    elif item_type == "digital":
        digital_section = section.get("digital", [None])[idx]
        if digital_section == None or digital_section.get("humidity") == None:
            return {
                "changed": False,
                "msg": "Sensor %d humidity not available" % (idx + 1),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
        value = digital_section["humidity"]
    else:
        return {
            "changed": False,
            "msg": "Unknown item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Determine state: upper thresholds
    if value >= crit:
        state = "CRIT"
    elif value >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    msg = "Humidity: %f%%" % value
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"humidity": value},
            "details": ""
        }
    }