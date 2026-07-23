# Module-level constants
SENSOR_OID_MAP = {
    "1.0": "Room",
    "2.0": "Outdoor",
    "3.0": "Delivery",
    "4.0": "Cold Water",
    "5.0": "Hot Water",
    "7.0": "Cold Water Outlet",
    "10.0": "Circuit 1 Suction",
    "11.0": "Circuit 2 Suction",
    "12.0": "Circuit 1 Evap",
    "13.0": "Circuit 2 Evap",
    "14.0": "Circuit 1 Superheat",
    "15.0": "Circuit 2 Superheat",
    "20.0": "Cooling Set Point",
    "21.0": "Cooling Prop. Band",
    "22.0": "Cooling 2nd Set Point",
    "23.0": "Heating Set Point",
    "24.0": "Heating 2nd Set Point",
    "25.0": "Heating Prop. Band",
}

# Default levels per sensor type (warn, crit in Celsius)
DEFAULT_LEVELS = {
    "Room": (30, 35),
    "Outdoor": (60, 70),
    "Delivery": (60, 70),
    "Cold Water": (60, 70),
    "Hot Water": (60, 70),
    "Cold Water Outlet": (60, 70),
    "Circuit 1 Suction": (60, 70),
    "Circuit 2 Suction": (60, 70),
    "Circuit 1 Evap": (60, 70),
    "Circuit 2 Evap": (60, 70),
    "Circuit 1 Superheat": (60, 70),
    "Circuit 2 Superheat": (60, 70),
    "Cooling Set Point": (60, 70),
    "Cooling Prop. Band": (60, 70),
    "Cooling 2nd Set Point": (60, 70),
    "Heating Set Point": (60, 70),
    "Heating 2nd Set Point": (60, 70),
    "Heating Prop. Band": (60, 70),
}

# Helper function to parse temperature values
def parse_sensors(string_table):
    parsed = {}
    for item in string_table:
        if len(item) < 2:
            continue
        oidend = item[0]
        value = item[1]
        sensor_name = SENSOR_OID_MAP.get(oidend)
        if sensor_name != None and value != None and value != "0" and value != "-9999":
            parsed[sensor_name] = float(value) / 10.0
    return parsed

# Helper function to determine state from temperature reading
def get_temperature_state(reading, warn, crit):
    if reading >= crit:
        return "CRIT"
    elif reading >= warn:
        return "WARN"
    else:
        return "OK"

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On",
            host,
            ".1.3.6.1.4.1.9839.2.1"
        ], mutates=False)
        
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP walk failed: " + res.stderr,
                "data": {"discovery": []}
            }
        
        # Parse SNMP output: each line is "OID = STRING: value"
        string_table = []
        for line in res.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            # Extract OID end (after base)
            if oid_part.startswith(".1.3.6.1.4.1.9839.2.1."):
                oidend = oid_part[len(".1.3.6.1.4.1.9839.2.1."):]
                # Extract value from "STRING: 1234" or similar
                if value_part.startswith("STRING: "):
                    value = value_part[len("STRING: "):]
                elif value_part.startswith("INTEGER: "):
                    value = value_part[len("INTEGER: "):]
                elif value_part.startswith("Gauge32: "):
                    value = value_part[len("Gauge32: "):]
                else:
                    value = value_part
                string_table.append([oidend, value])
        
        parsed = parse_sensors(string_table)
        
        discovery_list = []
        for sensor_name in parsed:
            levels = DEFAULT_LEVELS.get(sensor_name, (60, 70))
            discovery_list.append({
                "item": sensor_name,
                "params": {"levels": levels},
                "metrics": ["temp"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d sensors" % len(discovery_list),
            "data": {"discovery": discovery_list}
        }
    
    # Check mode: examine one item
    item = params.get("item", "")
    
    # Get SNMP data
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On",
        host,
        ".1.3.6.1.4.1.9839.2.1"
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed: " + res.stderr,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Parse SNMP output
    string_table = []
    for line in res.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        # Extract OID end (after base)
        if oid_part.startswith(".1.3.6.1.4.1.9839.2.1."):
            oidend = oid_part[len(".1.3.6.1.4.1.9839.2.1."):]
            # Extract value from "STRING: 1234" or similar
            if value_part.startswith("STRING: "):
                value = value_part[len("STRING: "):]
            elif value_part.startswith("INTEGER: "):
                value = value_part[len("INTEGER: "):]
            elif value_part.startswith("Gauge32: "):
                value = value_part[len("Gauge32: "):]
            else:
                value = value_part
            string_table.append([oidend, value])
    
    parsed = parse_sensors(string_table)
    
    # Check if item exists in parsed data
    if item not in parsed:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Get temperature reading and thresholds
    reading = parsed[item]
    levels = params.get("levels", DEFAULT_LEVELS.get(item, (60, 70)))
    warn = levels[0]
    crit = levels[1]
    
    # Determine state
    state = get_temperature_state(reading, warn, crit)
    
    # Format message
    msg = item + ": %f C" % reading
    
    # Return verdict
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temp": reading},
            "details": ""
        }
    }
