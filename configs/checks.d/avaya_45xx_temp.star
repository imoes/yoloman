# Constants defined at module top level
OID_BASE = ".1.3.6.1.4.1.45.1.6.3.7.1.1.5"
OID_SUFFIX = ".5"
SYSOID = ".1.3.6.1.2.1.1.2.0"
AVAYA_ENT_OID = ".1.3.6.1.4.1.45.3"

# Default thresholds from Checkmk plugin
DEFAULT_WARN = 55.0
DEFAULT_CRIT = 60.0

# Helper function to extract integer value from SNMP output line
def _parse_snmp_value(line):
    """Parse SNMP output line to extract value; return None if parsing fails"""
    if not line:
        return None
    line = line.strip()
    if not line:
        return None
    # Format: "OID = TYPE: value"
    if " = " not in line:
        return None
    parts = line.split(" = ", 1)
    if len(parts) != 2:
        return None
    value_part = parts[1].strip()
    # Extract actual value (type prefix like "INTEGER: " or "Gauge32: " etc.)
    if ": " in value_part:
        value_str = value_part.split(": ", 1)[1].strip()
    else:
        value_str = value_part
    # Convert to integer if possible
    return int(value_str) if value_str.isdigit() else None

def _snmpwalk(ctx, base_oid, host, community):
    """Perform snmpwalk on the base OID and return parsed results as list of values"""
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On",
        host,
        base_oid
    ], mutates=False)
    if res.rc != 0 or not res.stdout:
        return []
    lines = res.stdout.splitlines()
    results = []
    for line in lines:
        val = _parse_snmp_value(line)
        if val != None:
            results.append(val)
    return results

def _check_temperature(temp_value, warn, crit, state):
    """Determine temperature state based on thresholds"""
    # Higher than critical threshold -> CRIT
    if temp_value >= crit:
        state = "CRIT"
    # Higher than warning threshold -> WARN
    elif temp_value >= warn:
        state = "WARN"
    # Within normal range -> OK
    else:
        state = "OK"
    return state

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        
        # Detect if device is Avaya by checking sysObjectID
        sysoid_res = ctx.run([
            "snmpget",
            "-v2c",
            "-c", community,
            "-On",
            host,
            SYSOID
        ], mutates=False)
        
        # Skip if detection fails or sysoid doesn't match
        if sysoid_res.rc != 0 or not sysoid_res.stdout or AVAYA_ENT_OID not in sysoid_res.stdout:
            return {"changed": False, "msg": "not an Avaya 45xx device",
                    "data": {"discovery": []}}
        
        # Walk temperature sensor values
        temps = _snmpwalk(ctx, OID_BASE, host, community)
        
        # Build discovery list
        discovery_items = []
        for idx in range(len(temps)):
            item = str(idx)
            discovery_items.append({
                "item": item,
                "params": {"warn": DEFAULT_WARN, "crit": DEFAULT_CRIT},
                "metrics": ["temp"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }
    
    # Check mode for a specific item
    item = params.get("item", "")
    warn = params.get("warn", DEFAULT_WARN)
    crit = params.get("crit", DEFAULT_CRIT)
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Get all temperature values
    temps = _snmpwalk(ctx, OID_BASE, host, community)
    
    # Validate item index
    if not item.isdigit():
        return {
            "changed": False,
            "msg": "invalid item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    item_idx = int(item)
    
    # Check if item exists
    if item_idx < 0 or item_idx >= len(temps):
        return {
            "changed": False,
            "msg": "no such sensor: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Get temperature value
    raw_temp = temps[item_idx]
    
    # Convert to actual temperature (half-degree units)
    temp_value = float(raw_temp) / 2.0
    
    # Determine state
    state = "OK"
    state = _check_temperature(temp_value, warn, crit, state)
    
    # Build message
    msg = "Temperature: %f C" % temp_value
    
    # Add thresholds to message if not default
    if warn != DEFAULT_WARN or crit != DEFAULT_CRIT:
        msg += " (warn=%f, crit=%f)" % (warn, crit)
    
    # Return result
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temp": temp_value},
            "details": ""
        }
    }
